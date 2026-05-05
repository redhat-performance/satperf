#!/usr/bin/env python3
"""
trace_registration.py - Reconstruct per-connection registration traces from sosreports.

For every registration found in the satellite production.log (and correlated capsule
proxy.log entries), emits one JSON object per line (JSONL) containing the complete
ordered list of API calls made during that registration, with their timestamps and
durations.

This mirrors the per-connection view in ehelms/foreman-ai-harness/docs/foreman/
global-registration-api-analysis.md, but covers all registrations across all
topologies and concurrency levels simultaneously.

Usage:
  # All registrations from a test run
  ./trace_registration.py \\
    --run-url https://workdir-exporter.../run-2026-04-04T12:06:27+00:00/ \\
    --inventory conf/hosts.ini \\
    --no-verify-ssl \\
    --output traces.jsonl

  # Only direct registrations at concurrency 40
  ./trace_registration.py --run-url ... --topology direct --concurrency 40

  # Trace a specific UUID
  ./trace_registration.py --run-url ... --uuid ce269828-2747-410a-ad08-8e219d1cd932

Output (one JSON per line):
  {
    "uuid": "...", "topology": "direct", "capsule": "",
    "concurrency_level": 40, "started_at": "...", "ended_at": "...",
    "total_duration_ms": 27000, "success": true, "error_type": "ok",
    "calls": [
      {"ts": "...", "method": "GET", "path": "/register",
       "path_raw": "/register?activation_keys=...",
       "status": 200, "duration_ms": 825, "req_id": "e3c9c5ad",
       "backend": "foreman", "source_log": "satellite"},
      ...
    ]
  }
"""

import argparse
import datetime
import json
import logging
import re
import ssl
import sys
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Dict, Iterator, List, Optional, Set, Tuple

# Sibling modules — all live in scripts/registration/
sys.path.insert(0, str(Path(__file__).parent))
import registration_metrics as rm
from common import (
    ConcurrencyWindow,
    configure_ssl,
    load_run_data,
    _list_sosreports,
    _classify_sosreports,
    _lb_locations_from_topology,
    _classify_backend,
    _topo_category,
    _assign_concurrency,
    _fmt_ts,
    parse_measurement_log,
    TOPO_DIRECT, TOPO_STANDALONE, TOPO_LB,
)


# ---------------------------------------------------------------------------
# Dataclasses
# ---------------------------------------------------------------------------

@dataclass
class ApiCall:
    ts: str           # ISO format: "2026-04-04T17:59:38.000"
    method: str
    path: str         # stripped of query string
    path_raw: str     # full path including query string
    status: int
    duration_ms: int
    req_id: str
    backend: str      # candlepin | foreman | pulp | rhcloud | proxy | unknown
    source_log: str   # satellite | capsule-a-1 | etc.


@dataclass
class RegistrationTrace:
    uuid: str
    topology: str          # direct | standalone-capsule | lb-capsule
    capsule: str           # capsule name or '' for direct
    concurrency_level: int # 0 = not matched to any window
    started_at: str        # ISO format
    ended_at: str          # ISO format
    total_duration_ms: int
    success: bool
    error_type: str
    calls: List[ApiCall] = field(default_factory=list)


# _classify_backend, _topo_category, _assign_concurrency, _fmt_ts
# are all imported from common.

# ---------------------------------------------------------------------------
# Trace builder
# ---------------------------------------------------------------------------


def _build_trace(session: rm.RegistrationSession,
                 all_records: Dict,
                 capsule_records: Dict[str, Dict],
                 capsule_name: str,
                 topo_label: str,
                 window_sec: int = 300,
                 uuid_index: Optional[Dict[str, list]] = None,
                 path_indexes: Optional[Dict[str, list]] = None) -> RegistrationTrace:
    """Reconstruct the full ordered API call list for a single registration.

    Attribution strategy — ordered from most to least precise:

    1. UUID-keyed calls (unambiguous): any request whose path contains the
       consumer UUID (compliance, certificates, accessible_content, etc.).

    2. POST /rhsm/consumers: matched by timestamp proximity to t0 (±2s).

    3. GET /register (script delivery): the single nearest call BEFORE t0
       within a 30s look-back. At high concurrency many sessions fetch the
       script simultaneously; we take only the closest one to avoid pulling
       in neighbours' fetches.

    4. POST /register (host record): the first POST /register AFTER t0
       within window_sec. Only one is expected per session.

    5. GET /rhsm/ (resource discovery): the nearest call within ±5s of the
       GET /register we identified in step 3.

    6. GET /rhsm/status: NOT attributed individually — these calls cannot be
       reliably assigned at high concurrency (shared endpoint, no UUID). The
       count is already captured in session.status_calls; a synthetic summary
       call is added instead.

    7. Capsule proxy calls: GET/POST /register from the capsule proxy.log,
       matched by timestamp proximity to the satellite-side anchor events.
    """
    uuid = session.consumer_uuid
    t0 = session.started_at
    if t0 is None:
        t0 = datetime.datetime.min

    t_before = t0 - datetime.timedelta(seconds=30)
    t_after  = t0 + datetime.timedelta(seconds=window_sec)

    seen_req_ids: Set[str] = set()
    calls: List[ApiCall] = []

    def _add(r, source: str = 'satellite') -> None:
        if r.req_id in seen_req_ids:
            return
        seen_req_ids.add(r.req_id)
        path = r.path.split('?')[0]
        ts_str = _fmt_ts(r.ts)
        calls.append(ApiCall(
            ts=ts_str,
            method=r.method,
            path=path,
            path_raw=r.path,
            status=r.status,
            duration_ms=r.duration_ms,
            req_id=r.req_id,
            backend=_classify_backend(path),
            source_log=source,
        ))

    # --- Step 1: UUID-keyed calls ---
    # These are unambiguously tied to this consumer UUID (compliance, consumer
    # GET/PUT, certificates, accessible_content, etc.).
    # Use the pre-built uuid_index for O(1) lookup when available; fall back to
    # scanning all_records (O(n)) for callers that don't have the index.
    uuid_reqs = uuid_index.get(uuid, []) if (uuid_index and uuid != 'unknown') else (
        [r for r in all_records.values() if uuid != 'unknown' and uuid in r.path]
    )
    for r in uuid_reqs:
        if r.ts is not None and t_before <= r.ts <= t_after:
            _add(r)

    # --- Step 2: POST /rhsm/consumers anchor — exact req_id lookup ---
    if session.consumer_create_req_id and session.consumer_create_req_id in all_records:
        _add(all_records[session.consumer_create_req_id])
    else:
        # Fallback: proximity match (only reliable when no concurrent sessions)
        for r in all_records.values():
            if r.ts is None:
                continue
            path_clean = r.path.split('?')[0]
            if (r.method == 'POST' and rm._P_CONSUMER_CREATE.match(path_clean)
                    and abs((r.ts - t0).total_seconds()) < 2):
                _add(r)
                break  # take only one

    # --- Steps 3-5: path-indexed bisect lookups (O(log n)) ---
    # Falls back to O(n) full scan when path_indexes is not available.
    import bisect as _bisect

    script_ts = t_before  # updated if GET /register is found

    # Step 3: GET /register — nearest single call before t0 (within 30s)
    _idx = path_indexes.get('GET /register') if path_indexes else None
    if _idx:
        pos = _bisect.bisect_right(_idx, (t0, '\xff'))  # rightmost ts ≤ t0
        if pos > 0:
            ts_r, rid = _idx[pos - 1]
            if ts_r >= t_before and rid not in seen_req_ids and rid in all_records:
                _add(all_records[rid])
                script_ts = ts_r
    else:
        best_get_register = None
        best_delta = datetime.timedelta(seconds=31)
        for r in all_records.values():
            if r.ts is None or r.req_id in seen_req_ids:
                continue
            if r.method == 'GET' and rm._P_REGISTER.match(r.path.split('?')[0]):
                delta = t0 - r.ts
                if datetime.timedelta(0) <= delta < best_delta:
                    best_delta = delta
                    best_get_register = r
        if best_get_register:
            _add(best_get_register)
            script_ts = best_get_register.ts

    # Step 4: POST /register — first one after t0
    _idx = path_indexes.get('POST /register') if path_indexes else None
    if _idx:
        pos = _bisect.bisect_left(_idx, (t0, ''))
        if pos < len(_idx):
            ts_r, rid = _idx[pos]
            if ts_r <= t_after and rid not in seen_req_ids and rid in all_records:
                _add(all_records[rid])
    else:
        post_register = None
        for r in all_records.values():
            if r.ts is None or r.req_id in seen_req_ids:
                continue
            if r.method == 'POST' and rm._P_REGISTER.match(r.path.split('?')[0]) and r.ts >= t0:
                if post_register is None or r.ts < post_register.ts:
                    post_register = r
        if post_register:
            _add(post_register)

    # Step 5: GET /rhsm/ — nearest to script fetch
    _idx = path_indexes.get('GET /rhsm/') if path_indexes else None
    if _idx:
        pos = _bisect.bisect_left(_idx, (script_ts, ''))
        best_disc = None
        best_disc_delta = datetime.timedelta(seconds=6)
        for p in (pos - 1, pos):
            if 0 <= p < len(_idx):
                ts_r, rid = _idx[p]
                delta = abs(ts_r - script_ts)
                if delta < best_disc_delta and rid not in seen_req_ids:
                    best_disc_delta = delta
                    best_disc = (ts_r, rid)
        if best_disc:
            _, rid = best_disc
            if rid in all_records:
                _add(all_records[rid])
    else:
        best_rhsm_disc = None
        best_disc_delta = datetime.timedelta(seconds=6)
        for r in all_records.values():
            if r.ts is None or r.req_id in seen_req_ids:
                continue
            if r.method == 'GET' and r.path.split('?')[0] == '/rhsm/':
                delta = abs(r.ts - script_ts)
                if delta < best_disc_delta:
                    best_disc_delta = delta
                    best_rhsm_disc = r
        if best_rhsm_disc:
            _add(best_rhsm_disc)

    # --- Step 6: GET /rhsm/status synthetic summary ---
    # Cannot be individually attributed at high concurrency; represent as one
    # synthetic entry using the session-level aggregate count.
    if session.status_calls > 0:
        calls.append(ApiCall(
            ts=_fmt_ts(t0),
            method='GET',
            path='/rhsm/status',
            path_raw='/rhsm/status',
            status=200,
            duration_ms=0,   # no individual timing available
            req_id='(aggregate)',
            backend='candlepin',
            source_log='satellite',
        ))

    # --- Step 7: Capsule proxy calls ---
    # The capsule POST /register STARTS before t0 (client hits capsule, capsule
    # forwards to satellite which then runs POST /rhsm/consumers at t0).
    # So we search in [t_before, t0] for the started timestamp, not [t0, t_after].
    # The GET /register is anchored from the capsule POST, not from the satellite-side
    # script fetch, because both live in the same proxy.log and their relative ordering
    # is reliable at high concurrency.
    if capsule_name and capsule_name in capsule_records:
        proxy_recs = capsule_records[capsule_name]

        # Find capsule POST /register first (started before consumer create at t0)
        best_cap_post = None
        best_cap_post_delta = datetime.timedelta(seconds=window_sec + 1)
        for r in proxy_recs.values():
            if r.ts is None:
                continue
            path_clean = r.path.split('?')[0]
            if r.method == 'POST' and rm._P_REGISTER.match(path_clean):
                # The POST can start up to window_sec before t0 or a few seconds after
                if t_before <= r.ts <= (t0 + datetime.timedelta(seconds=30)):
                    delta = abs(r.ts - t0)
                    if delta < best_cap_post_delta:
                        best_cap_post_delta = delta
                        best_cap_post = r

        # Find capsule GET /register — nearest before the capsule POST /register
        # (same approach as _pass2_proxy: script fetch precedes the registration)
        cap_post_ts = best_cap_post.ts if best_cap_post else t_before
        best_cap_get = None
        best_cap_get_delta = datetime.timedelta(seconds=window_sec + 1)
        for r in proxy_recs.values():
            if r.ts is None:
                continue
            path_clean = r.path.split('?')[0]
            if r.method == 'GET' and rm._P_REGISTER.match(path_clean):
                # Must be before (or at same second as) the capsule POST
                delta = cap_post_ts - r.ts
                if datetime.timedelta(0) <= delta < best_cap_get_delta:
                    best_cap_get_delta = delta
                    best_cap_get = r

        if best_cap_get and best_cap_get.req_id not in seen_req_ids:
            seen_req_ids.add(best_cap_get.req_id)
            calls.append(ApiCall(
                ts=_fmt_ts(best_cap_get.ts),
                method=best_cap_get.method,
                path=best_cap_get.path.split('?')[0],
                path_raw=best_cap_get.path,
                status=best_cap_get.status,
                duration_ms=best_cap_get.duration_ms,
                req_id=best_cap_get.req_id,
                backend='proxy',
                source_log=capsule_name,
            ))

        if best_cap_post and best_cap_post.req_id not in seen_req_ids:
            seen_req_ids.add(best_cap_post.req_id)
            calls.append(ApiCall(
                ts=_fmt_ts(best_cap_post.ts),
                method=best_cap_post.method,
                path=best_cap_post.path.split('?')[0],
                path_raw=best_cap_post.path,
                status=best_cap_post.status,
                duration_ms=best_cap_post.duration_ms,
                req_id=best_cap_post.req_id,
                backend='proxy',
                source_log=capsule_name,
            ))

    calls.sort(key=lambda c: c.ts)

    started_str = _fmt_ts(t0)
    ended_ts = calls[-1].ts if calls else started_str
    if calls:
        # Compute total duration as wall-clock span of calls
        try:
            last_call = max(calls, key=lambda c: c.ts)
            last_ts = datetime.datetime.strptime(last_call.ts, '%Y-%m-%dT%H:%M:%S.%f')
            total_ms = int((last_ts - t0).total_seconds() * 1000) + last_call.duration_ms
        except Exception:
            total_ms = session.consumer_create_ms
    else:
        total_ms = session.consumer_create_ms

    success = session.consumer_create_status in (0, 200, 201)
    return RegistrationTrace(
        uuid=uuid,
        topology=topo_label,
        capsule=capsule_name,
        concurrency_level=0,  # assigned later
        started_at=started_str,
        ended_at=ended_ts,
        total_duration_ms=total_ms,
        success=success,
        error_type=rm._error_type(session.consumer_create_status),
        calls=calls,
    )


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument('--run-url', required=True, metavar='URL',
                        help='Base URL of the test run directory')
    parser.add_argument('--inventory', metavar='FILE',
                        help='Ansible INI inventory for topology classification')
    parser.add_argument('--no-verify-ssl', action='store_true',
                        help='Disable SSL certificate verification')
    parser.add_argument('--topology', metavar='TYPE',
                        choices=['direct', 'standalone', 'lb'],
                        help='Filter: only emit traces for this topology')
    parser.add_argument('--concurrency', metavar='N[,N...]',
                        help='Filter: only emit traces from these concurrency levels')
    parser.add_argument('--uuid', metavar='UUID',
                        help='Trace a specific consumer UUID only')
    parser.add_argument('--max-traces', metavar='N', type=int, default=0,
                        help='Cap total output (default: all)')
    parser.add_argument('--output', metavar='FILE', default='-',
                        help='Output JSONL file (default: stdout)')
    parser.add_argument('--window', metavar='SECONDS', type=int, default=300,
                        help='Time window around session start to search for calls (default: 300)')
    parser.add_argument('--cache-dir', metavar='DIR',
                        help='Cache extracted log files; subsequent runs skip '
                             'download+decompress (~10 min → <30 s)')
    parser.add_argument('-v', '--verbose', action='store_true',
                        help='Enable debug logging to stderr')
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format='%(levelname)s: %(message)s',
        stream=sys.stderr,
    )

    # Parse filters
    concurrency_filter: Set[int] = set()
    if args.concurrency:
        concurrency_filter = {int(x.strip()) for x in args.concurrency.split(',')}

    topo_filter_map = {
        'direct': TOPO_DIRECT,
        'standalone': TOPO_STANDALONE,
        'lb': TOPO_LB,
    }
    topo_filter = topo_filter_map.get(args.topology) if args.topology else None

    # Load all data via the shared pipeline (records cache + raw log cache)
    try:
        run_data = load_run_data(
            args.run_url,
            inventory=args.inventory,
            no_verify_ssl=args.no_verify_ssl,
            cache_dir=args.cache_dir,
        )
    except RuntimeError as exc:
        logging.error('%s', exc)
        sys.exit(1)

    # --- Build and emit traces ---
    out = open(args.output, 'w') if args.output != '-' else sys.stdout
    emitted = 0

    try:
        for session in run_data.sat_sessions:
            if args.uuid and session.consumer_uuid != args.uuid:
                continue

            topo_label, cap_name = _topo_category(session, run_data.lb_locations)

            if topo_filter and topo_label != topo_filter:
                continue

            concurrency_level = _assign_concurrency(session, run_data.windows)
            if concurrency_filter and concurrency_level not in concurrency_filter:
                continue

            trace = _build_trace(
                session, run_data.sat_records, run_data.capsule_records,
                cap_name, topo_label, args.window,
                uuid_index=run_data.uuid_index,
                path_indexes=run_data.path_indexes,
            )
            trace.concurrency_level = concurrency_level

            out.write(json.dumps(asdict(trace)) + '\n')
            emitted += 1

            if args.max_traces and emitted >= args.max_traces:
                break

    finally:
        if args.output != '-':
            out.close()

    logging.info('Emitted %d traces', emitted)


if __name__ == '__main__':
    main()
