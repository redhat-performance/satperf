#!/usr/bin/env python3
"""
generate_registration_analysis.py - Generate a Markdown registration observability
analysis from sosreports and measurement.log data.

Reads:
  - measurement.log  (per-concurrency timing windows and pass/fail counts)
  - satellite sosreport tarball  (Foreman production.log → server-side metrics)
  - capsule sosreport tarballs   (foreman-proxy proxy.log → capsule-side metrics)

Writes the complete Markdown document to stdout.

Usage:
  ./generate_registration_analysis.py \\
    --run-url https://workdir-exporter.../run-2026-04-04T12:06:27+00:00/ \\
    --inventory conf/hosts.ini \\
    [--no-verify-ssl] \\
    > docs/registration-observability-analysis.md
"""

import argparse
import datetime
import logging
import re
import sys
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple

# Sibling modules
sys.path.insert(0, str(__import__('pathlib').Path(__file__).parent))
import registration_metrics as rm
from common import (
    ConcurrencyWindow,
    load_run_data,
    _filter_reg_records,
)


@dataclass
class AnalysisData:
    run_url: str
    generated_at: datetime.datetime
    # From measurement.log
    sat_version: str = 'unknown'
    katello_version: str = 'unknown'
    windows: List[ConcurrencyWindow] = field(default_factory=list)
    # Satellite-side: topology label → Metrics (whole-run aggregate)
    sat_aggregate: Dict[str, rm.Metrics] = field(default_factory=dict)
    # Satellite-side: (level, topology) → Metrics
    sat_by_level: Dict[Tuple[int, str], rm.Metrics] = field(default_factory=dict)
    # Capsule-side: capsule_name → Metrics (whole-run aggregate)
    capsule_aggregate: Dict[str, rm.Metrics] = field(default_factory=dict)
    # Capsule-side: (level, capsule_name) → Metrics
    capsule_by_level: Dict[Tuple[int, str], rm.Metrics] = field(default_factory=dict)
    # Cache stats — zero/absent when PRs not applied; check has_data before rendering
    sat_cache_stats: Optional[rm.CacheStats] = None
    capsule_cache_stats: Dict[str, rm.CacheStats] = field(default_factory=dict)


# ---------------------------------------------------------------------------
# Data collection
# ---------------------------------------------------------------------------


def _collect_satellite_data(
        sat_url: str,
        windows: List[ConcurrencyWindow],
        topology: Optional[Dict],
        lb_locations: Optional[set] = None,
        cache_dir: Optional[str] = None) -> Tuple[
            Dict[str, rm.Metrics], Dict[Tuple[int, str], rm.Metrics]]:
    """Parse satellite production.log once; query each concurrency window."""
    from common import _read_cached_lines, _write_cache
    from pathlib import Path

    cache = Path(cache_dir) if cache_dir else None
    cache_path = (cache / (sat_url.split('/')[-1].replace('.tar.xz', '')
                           + '_production.log')) if cache else None

    all_lines = (cache_path and _read_cached_lines(cache_path)) or None
    if all_lines is None:
        logging.info('Streaming satellite production.log from %s', sat_url)
        all_lines = list(rm._production_log_lines_from_tarball(sat_url))
        if cache_path:
            _write_cache(cache_path, all_lines)
    else:
        logging.info('Satellite: using cached production.log')
    logging.info('Satellite: %d log lines', len(all_lines))

    all_records = rm._pass1(iter(all_lines))
    logging.info('Satellite: %d total request records', len(all_records))

    records = _filter_reg_records(all_records)
    del all_records  # release memory
    logging.info('Satellite: %d registration-relevant records (after pre-filter)',
                 len(records))

    # Single pass2 over all records — then split sessions by time window.
    # Calling pass2 once avoids O(n²) repeat of the inner window-matching loops.
    logging.info('Satellite: running _pass2 (single call, will split by window)')
    all_sessions = rm._pass2(records, window_sec=120, topology=topology)
    logging.info('Satellite: %d total registration sessions', len(all_sessions))

    # Whole-run aggregate
    aggregate = _group_sessions(all_sessions, 'all runs', lb_locations)

    # Per-concurrency-level: filter sessions by start timestamp
    by_level: Dict[Tuple[int, str], rm.Metrics] = {}
    for w in windows:
        window_sessions = [
            s for s in all_sessions
            if s.started_at and w.since_dt <= s.started_at <= w.until_dt
        ]
        metrics = _group_sessions(window_sessions, f'concurrency={w.level}', lb_locations)
        for label, m in metrics.items():
            by_level[(w.level, label)] = m

    return aggregate, by_level


_TOPO_ORDER = ['Direct (satellite)', 'Standalone capsules', 'Load-balanced capsules']


def _lb_locations_from_topology(topology: Optional[Dict]) -> set:
    """Return the set of location letters that have an LB entry in the topology.

    Naming convention: 'capsule-lb-X' is the LB for location X, so
    'capsule-X-N' backend nodes belong to the load-balanced topology.
    Example: capsule-lb-d → location 'd'; capsule-d-1, capsule-d-2 are LB backends.
    """
    if not topology:
        return set()
    locations = set()
    for _ip, (role, hostname, _rex) in topology.items():
        if role == 'lb':
            m = re.match(r'capsule-lb-([a-z])', hostname)
            if m:
                locations.add(m.group(1))
    return locations


def _group_sessions(sessions, source_label: str,
                    lb_locations: Optional[set] = None) -> Dict[str, rm.Metrics]:
    """Group sessions by topology category and build Metrics per group.

    lb_locations: set of location letters (e.g. {'d'}) whose capsule-X-N backend
    nodes should be classified as 'Load-balanced capsules' rather than
    'Standalone capsules'.  Derived from inventory via _lb_locations_from_topology().
    """
    import collections

    _lb = lb_locations or set()

    def _category(s: rm.RegistrationSession) -> str:
        if s.routing == 'direct':
            return 'Direct (satellite)'
        if s.routing.startswith('lb:'):
            return 'Load-balanced capsules'
        # capsule:capsule-X-N.hostname — check location letter
        hostname = s.routing.split(':', 1)[1] if ':' in s.routing else ''
        m = re.match(r'capsule-([a-z])-\d+', hostname)
        if m and m.group(1) in _lb:
            return 'Load-balanced capsules'
        return 'Standalone capsules'

    groups: Dict[str, list] = collections.defaultdict(list)
    for s in sessions:
        groups[_category(s)].append(s)

    result = {}
    for cat in _TOPO_ORDER:
        if cat in groups:
            result[cat] = rm._build_metrics(groups[cat], cat)
    return result


def _collect_capsule_data(
        capsule_urls: Dict[str, str],
        windows: List[ConcurrencyWindow],
        cache_dir: Optional[str] = None) -> Tuple[
            Dict[str, rm.Metrics], Dict[Tuple[int, str], rm.Metrics]]:
    """Parse each capsule proxy.log once; query each concurrency window."""
    from common import _read_cached_lines, _write_cache
    from pathlib import Path

    cache = Path(cache_dir) if cache_dir else None
    aggregate: Dict[str, rm.Metrics] = {}
    by_level: Dict[Tuple[int, str], rm.Metrics] = {}

    for cap_name, cap_url in sorted(capsule_urls.items()):
        cap_cache = (cache / (cap_url.split('/')[-1].replace('.tar.xz', '')
                              + '_proxy.log')) if cache else None
        all_lines = (cap_cache and _read_cached_lines(cap_cache)) or None
        if all_lines is None:
            logging.info('Streaming %s proxy.log from %s', cap_name, cap_url)
            all_lines = list(rm.proxy_log_lines_from_tarball(cap_url))
            if cap_cache:
                _write_cache(cap_cache, all_lines)
        else:
            logging.info('%s: using cached proxy.log', cap_name)
        logging.info('%s: %d proxy log lines', cap_name, len(all_lines))

        all_proxy_records = rm._pass1_proxy(iter(all_lines))
        logging.info('%s: %d total request records', cap_name, len(all_proxy_records))
        # Proxy.log only contains /register and a handful of other paths;
        # filter to /register to keep _pass2_proxy fast.
        records = {k: v for k, v in all_proxy_records.items()
                   if rm._P_REGISTER.match(v.path.split('?')[0])}
        del all_proxy_records
        logging.info('%s: %d /register records', cap_name, len(records))

        # Single pass2 call, then split by time window (avoids O(n²) repeat)
        all_sessions = rm._pass2_proxy(records, window_sec=300)
        aggregate[cap_name] = rm._build_metrics(all_sessions, cap_name)

        for w in windows:
            window_sessions = [
                s for s in all_sessions
                if s.started_at and w.since_dt <= s.started_at <= w.until_dt
            ]
            by_level[(w.level, cap_name)] = rm._build_metrics(
                window_sessions, f'{cap_name} concurrency={w.level}')

    return aggregate, by_level


# ---------------------------------------------------------------------------
# Markdown rendering helpers
# ---------------------------------------------------------------------------

def _pct(vals, p: float) -> int:
    return rm._pct(vals, p)


def _fmt_ms(ms: int) -> str:
    return f'{ms:,}' if ms else '—'


def _ms_table_row(label: str, vals) -> str:
    if not vals:
        return f'| {label} | — | — | — | — |'
    p50, p95, p99 = rm._p50_p95_p99(vals)
    avg = rm._avg(vals)
    return f'| {label} | {avg:,.0f} | {p50:,} | {p95:,} | {p99:,} |'


def _count_table_row(label: str, vals) -> str:
    if not vals:
        return f'| {label} | — | — | — | — |'
    avg = rm._avg(vals)
    p50, p95, p99 = rm._p50_p95_p99(vals)
    return f'| {label} | {avg:.1f} | {p50} | {p95} | {p99} |'


def _metrics_section(m: rm.Metrics, heading_prefix: str = '###') -> str:
    """Render a Metrics object as Markdown tables."""
    lines = []
    if m.session_count == 0:
        lines.append('*No sessions found in this window.*')
        return '\n'.join(lines)

    w0 = m.window_start.strftime('%Y-%m-%d %H:%M:%S UTC') if m.window_start else '?'
    w1 = m.window_end.strftime('%Y-%m-%d %H:%M:%S UTC') if m.window_end else '?'
    lines.append(f'Sessions: **{m.session_count:,}** &nbsp; Window: {w0} → {w1}')
    if m.error_count:
        pct = m.error_count / m.session_count * 100
        breakdown = ', '.join(f'{k}: {v}' for k, v in sorted(m.error_breakdown.items()))
        lines.append(f'Errors: **{m.error_count}** ({pct:.1f}%) — {breakdown}')
    lines.append('')
    lines.append('| Metric (ms) | Avg | P50 | P95 | P99 |')
    lines.append('|---|---:|---:|---:|---:|')
    if m.consumer_create_ms:
        lines.append(_ms_table_row('POST /rhsm/consumers', m.consumer_create_ms))
    if m.script_fetch_ms:
        lines.append(_ms_table_row('GET /register (script fetch)', m.script_fetch_ms))
    if m.host_register_ms:
        lines.append(_ms_table_row('POST /register (host record)', m.host_register_ms))
    if m.fact_update_ms:
        lines.append(_ms_table_row('PUT /rhsm/consumers/:id (facts)', m.fact_update_ms))

    has_counts = m.compliance_calls or m.status_calls or m.redundant_consumer_gets
    if has_counts:
        lines.append('')
        lines.append('| Call counts (per session) | Avg | P50 | P95 | P99 |')
        lines.append('|---|---:|---:|---:|---:|')
        if m.compliance_calls:
            lines.append(_count_table_row('GET /compliance calls', m.compliance_calls))
        if m.status_calls:
            lines.append(_count_table_row('GET /rhsm/status calls', m.status_calls))
        if m.redundant_consumer_gets:
            lines.append(_count_table_row(
                'GET /rhsm/consumers/:id (redundant)', m.redundant_consumer_gets))

    return '\n'.join(lines)


# ---------------------------------------------------------------------------
# Document rendering
# ---------------------------------------------------------------------------

def render_document(data: AnalysisData) -> str:
    out = []

    def h(level: int, text: str):
        out.append(f'\n{"#" * level} {text}\n')

    def p(*lines):
        for line in lines:
            out.append(line)
        out.append('')

    generated = data.generated_at.strftime('%Y-%m-%d %H:%M UTC')
    h(1, 'Satellite Registration Observability Analysis')
    p(
        f'**Generated:** {generated}  ',
        f'**Source:** {data.run_url}  ',
        f'**Satellite:** {data.sat_version} &nbsp; **Katello:** {data.katello_version}',
    )

    # ------------------------------------------------------------------ §1
    h(2, 'Overview')
    p(
        'This document characterises the end-to-end registration latency of Red Hat '
        'Satellite hosts across three distinct network topologies and eighteen '
        'concurrency levels. It combines server-side timing from the Foreman '
        '`production.log` (satellite) with capsule-side timing from '
        '`foreman-proxy/proxy.log` (capsule nodes) to give a complete view of '
        'where time is spent during the `subscription-manager register` flow.',
        '',
        'The three registration paths under test:',
        '',
        '| Path | Description |',
        '|---|---|',
        '| **Direct (satellite)** | Container hosts (`hq-*`) register directly to the Satellite. |',
        '| **Standalone capsules** | Container hosts (`a-*`, `b-*`) register via a dedicated capsule (no load balancer). |',
        '| **Load-balanced capsules** | Container hosts (`c-*`) register via an HAProxy front-end distributing across two capsule nodes. |',
    )

    # ------------------------------------------------------------------ §2
    h(2, 'Test Environment')
    p(
        '| Component | Details |',
        '|---|---|',
        f'| Satellite version | {data.sat_version} |',
        f'| Katello version | {data.katello_version} |',
        '| OS | RHEL 9 |',
        '| Capsule topology | 2 standalone capsules (a, b) + 1 LB pair (c-1, c-2 behind HAProxy) |',
        '| Container hosts | 10 total — 2 direct (hq), 2×2 standalone, 4 LB |',
        f'| Concurrency levels tested | {", ".join(str(w.level) for w in data.windows)} |',
        '| REX mode | SSH (direct, standalone) and MQTT pull (standalone capsules) |',
    )

    # ------------------------------------------------------------------ §3
    h(2, 'Registration Topologies')

    h(3, '3.1 Direct to Satellite')
    p(
        '```',
        'Container  ──GET /register──►  Satellite (foreman-proxy)',
        '           ◄── script ────────',
        '           ──POST /register──►  Satellite (Foreman)',
        '             ├─POST /rhsm/consumers──► Candlepin',
        '             ├─GET  /compliance ×N ──► Candlepin',
        '             ├─GET  /rhsm/status ×N ──► Candlepin',
        '             └─PUT  /rhsm/consumers/:id (facts)',
        '```',
    )

    h(3, '3.2 Standalone Capsule')
    p(
        '```',
        'Container  ──GET /register──►  Capsule (foreman-proxy, may be cached)',
        '           ◄── script ────────',
        '           ──POST /register──►  Capsule (foreman-proxy)',
        '             └─POST /register──►  Satellite (Foreman)',
        '                 ├─POST /rhsm/consumers ──► Candlepin (via capsule RHSM proxy)',
        '                 ├─GET  /compliance ×N  ──► Candlepin',
        '                 ├─GET  /rhsm/status ×N ──► Candlepin',
        '                 └─PUT  /rhsm/consumers/:id (facts)',
        '```',
        '',
        '> RHSM calls (`/rhsm/consumers`, `/compliance`, `/rhsm/status`) are proxied',
        '> through the capsule\'s RHSM reverse proxy (httpd/Pulpcore) and appear in',
        '> the satellite\'s `production.log` with the capsule\'s source IP.',
    )

    h(3, '3.3 Load-Balanced Capsule')
    p(
        '```',
        'Container  ──GET /register──►  HAProxy  ──►  Capsule C-1 or C-2',
        '           ◄── script ─────────────────────',
        '           ──POST /register──►  HAProxy  ──►  Capsule C-1 or C-2',
        '                                              └─ (same as standalone path above)',
        '```',
        '',
        '> Individual capsule nodes (c-1, c-2) appear separately in the proxy.log',
        '> metrics below. The satellite sees requests from whichever capsule node',
        '> handled the RHSM call.',
    )

    # ------------------------------------------------------------------ §4
    h(2, 'Satellite-side Metrics (Aggregate)')
    p(
        'Metrics derived from `production.log` on the Satellite, covering the full',
        'test run. Sessions are classified by the source IP of `POST /rhsm/consumers`:',
        'capsule IPs (proxied registrations) vs. direct container IPs.',
    )

    if data.sat_aggregate:
        for topo, m in data.sat_aggregate.items():
            h(3, topo)
            out.append(_metrics_section(m))
            out.append('')
    else:
        p('*No satellite-side data collected.*')

    # ------------------------------------------------------------------ §5
    h(2, 'Capsule-side Metrics (Aggregate)')
    p(
        'Metrics derived from `foreman-proxy/proxy.log` on each capsule node.',
        'Only `GET /register` (script delivery) and `POST /register` (total',
        'end-to-end registration as seen by the capsule) are visible here.',
        'RHSM sub-calls are proxied via httpd and do not appear in proxy.log.',
    )

    if data.capsule_aggregate:
        for cap_name, m in sorted(data.capsule_aggregate.items()):
            h(3, cap_name)
            out.append(_metrics_section(m))
            out.append('')
    else:
        p('*No capsule-side data collected.*')

    # ------------------------------------------------------------------ §6
    h(2, 'Cache Hit Rates')

    sat_cs = data.sat_cache_stats
    cap_cs = data.capsule_cache_stats
    any_cache_data = (sat_cs and sat_cs.has_data) or any(
        cs.has_data for cs in cap_cs.values()
    )

    if any_cache_data:
        out.append(
            'HIT/MISS counts from `production.log` (`:registration` logger, katello#11692/'
            'katello#11696) and `proxy.log` (smart-proxy#935).  Only present when those PRs '
            'are applied and logging is enabled at the required level.'
        )
        out.append('')
        out.append('| Source | Cache | Hits | Misses | Total | Hit Rate | PR |')
        out.append('|---|---|---:|---:|---:|---:|---|')
        if sat_cs and sat_cs.has_data:
            total_c = sat_cs.compliance_hits + sat_cs.compliance_misses
            if total_c:
                out.append(
                    f'| Satellite | `GET /compliance` | {sat_cs.compliance_hits:,} | '
                    f'{sat_cs.compliance_misses:,} | {total_c:,} | '
                    f'{sat_cs.compliance_rate} | katello#11692 |'
                )
            total_s = sat_cs.status_hits + sat_cs.status_misses
            if total_s:
                out.append(
                    f'| Satellite | `GET /rhsm/status` | {sat_cs.status_hits:,} | '
                    f'{sat_cs.status_misses:,} | {total_s:,} | '
                    f'{sat_cs.status_rate} | katello#11696 |'
                )
        for cap_name, cs in sorted(cap_cs.items()):
            total_sc = cs.script_hits + cs.script_misses
            if total_sc:
                out.append(
                    f'| {cap_name} | `GET /register` (script) | {cs.script_hits:,} | '
                    f'{cs.script_misses:,} | {total_sc:,} | '
                    f'{cs.script_rate} | smart-proxy#935 |'
                )
        out.append('')
    else:
        p(
            '*No cache HIT/MISS data found.  Either the caching PRs (katello#11692, '
            'katello#11696, smart-proxy#935) have not been applied, or the '
            '`:registration` logger is not enabled at `debug` level.*',
        )

    # ------------------------------------------------------------------ §7
    h(2, 'Concurrency Impact')
    p(
        'Each row represents one complete concurrency sweep: all container hosts',
        'registering simultaneously with the given `concurrent_total`. The pass rate',
        'is computed client-side (Ansible task success/failure).',
    )

    h(3, '6.1 Overall Pass Rate and Latency')
    out.append('| Concurrent | Passed | Failed | Success % | Avg Duration (s) |')
    out.append('|---:|---:|---:|---:|---:|')
    for w in data.windows:
        out.append(
            f'| {w.level} | {w.passed} | {w.failed} | {w.success_pct:.1f}% '
            f'| {w.avg_duration_s:.1f} |'
        )
    out.append('')

    # Satellite-side per-level summary
    h(3, '6.2 Server-side Sessions by Concurrency Level')
    p(
        'Session counts and P50 consumer-create latency from `production.log`,',
        'broken down by topology category.',
    )

    all_topos = sorted({topo for (_lvl, topo) in data.sat_by_level})
    if all_topos:
        header = '| Concurrent | ' + ' | '.join(
            f'{t} (n / P50 ms)' for t in all_topos) + ' |'
        sep = '|---:' + '|---:' * len(all_topos) + '|'
        out.append(header)
        out.append(sep)
        for w in data.windows:
            cells = []
            for topo in all_topos:
                m = data.sat_by_level.get((w.level, topo))
                if m and m.session_count:
                    p50 = rm._pct(m.consumer_create_ms, 50) if m.consumer_create_ms else 0
                    cells.append(f'{m.session_count} / {p50:,}')
                else:
                    cells.append('—')
            out.append(f'| {w.level} | ' + ' | '.join(cells) + ' |')
        out.append('')
    else:
        p('*No per-level satellite data available (topology map required).*')

    # Capsule-side per-level POST /register P50
    h(3, '6.3 Capsule-side POST /register Latency by Concurrency Level')
    p(
        'P50 of total registration duration as seen by each capsule proxy.',
        'This reflects the end-to-end time experienced by the client (HAProxy',
        'add-on latency not included for LB capsules).',
    )

    all_caps = sorted({cap for (_lvl, cap) in data.capsule_by_level})
    if all_caps:
        header = '| Concurrent | ' + ' | '.join(
            f'{c} (n / P50 ms)' for c in all_caps) + ' |'
        sep = '|---:' + '|---:' * len(all_caps) + '|'
        out.append(header)
        out.append(sep)
        for w in data.windows:
            cells = []
            for cap in all_caps:
                m = data.capsule_by_level.get((w.level, cap))
                if m and m.session_count:
                    p50 = rm._pct(m.host_register_ms, 50) if m.host_register_ms else 0
                    cells.append(f'{m.session_count} / {p50:,}')
                else:
                    cells.append('—')
            out.append(f'| {w.level} | ' + ' | '.join(cells) + ' |')
        out.append('')
    else:
        p('*No capsule-side per-level data available.*')

    # ------------------------------------------------------------------ §7
    h(2, 'Error Analysis')
    p(
        'Errors are classified by HTTP status from `POST /rhsm/consumers` (satellite',
        'side) and `POST /register` (capsule side).',
    )

    h(3, '7.1 Satellite-side Errors by Concurrency Level')
    has_errors = any(
        data.sat_by_level.get((w.level, t), rm.Metrics('', None, None, 0)).error_count > 0
        for w in data.windows
        for t in all_topos
    )
    if has_errors:
        for topo in all_topos:
            topo_has_errors = any(
                data.sat_by_level.get((w.level, topo),
                                     rm.Metrics('', None, None, 0)).error_count > 0
                for w in data.windows
            )
            if not topo_has_errors:
                continue
            out.append(f'**{topo}**')
            out.append('')
            out.append('| Concurrent | Errors | Error Types |')
            out.append('|---:|---:|---|')
            for w in data.windows:
                m = data.sat_by_level.get((w.level, topo))
                if m and m.error_count:
                    breakdown = ', '.join(
                        f'{k}: {v}' for k, v in sorted(m.error_breakdown.items()))
                    out.append(f'| {w.level} | {m.error_count} | {breakdown} |')
            out.append('')
    else:
        p('No errors recorded in satellite-side data.')

    h(3, '7.2 Capsule-side Errors by Concurrency Level')
    has_cap_errors = any(
        data.capsule_by_level.get((w.level, c),
                                  rm.Metrics('', None, None, 0)).error_count > 0
        for w in data.windows
        for c in all_caps
    )
    if has_cap_errors:
        for cap in sorted(all_caps):
            cap_has_errors = any(
                data.capsule_by_level.get((w.level, cap),
                                         rm.Metrics('', None, None, 0)).error_count > 0
                for w in data.windows
            )
            if not cap_has_errors:
                continue
            out.append(f'**{cap}**')
            out.append('')
            out.append('| Concurrent | Errors | Error Types |')
            out.append('|---:|---:|---|')
            for w in data.windows:
                m = data.capsule_by_level.get((w.level, cap))
                if m and m.error_count:
                    breakdown = ', '.join(
                        f'{k}: {v}' for k, v in sorted(m.error_breakdown.items()))
                    out.append(f'| {w.level} | {m.error_count} | {breakdown} |')
            out.append('')
    else:
        p('No errors recorded in capsule-side data.')

    # ------------------------------------------------------------------ §8
    h(2, 'Bottlenecks and Recommendations')

    # Derive a few data-driven observations
    observations = []

    # Consumer create latency trend
    if data.windows:
        low_w = data.windows[0]
        high_w = next((w for w in reversed(data.windows) if w.passed > 0), None)
        if high_w and high_w.avg_duration_s > low_w.avg_duration_s * 1.5:
            factor = high_w.avg_duration_s / low_w.avg_duration_s
            observations.append(
                f'Average registration duration grows **{factor:.1f}×** '
                f'from {low_w.level} to {high_w.level} concurrent registrations '
                f'({low_w.avg_duration_s:.0f}s → {high_w.avg_duration_s:.0f}s), '
                f'indicating non-linear pressure on the Candlepin/Foreman stack.'
            )

        # First concurrency level with failures
        first_failure = next((w for w in data.windows if w.failed > 0), None)
        if first_failure:
            observations.append(
                f'Client-side failures first appear at **{first_failure.level}** '
                f'concurrent registrations ({first_failure.failed} failures, '
                f'{first_failure.success_pct:.1f}% success rate).'
            )

    # Compliance call count
    for topo, m in data.sat_aggregate.items():
        if m.compliance_calls:
            avg_compliance = rm._avg(m.compliance_calls)
            if avg_compliance > 1.5:
                observations.append(
                    f'**{topo}**: average {avg_compliance:.1f} `GET /compliance` '
                    f'calls per registration (target: 1). '
                    f'Consider compliance caching (katello#11692).'
                )

    # Status calls
    for topo, m in data.sat_aggregate.items():
        if m.status_calls:
            avg_status = rm._avg(m.status_calls)
            if avg_status > 1.5:
                observations.append(
                    f'**{topo}**: average {avg_status:.1f} `GET /rhsm/status` '
                    f'calls per registration (target: 1). '
                    f'Consider status caching (katello#11696).'
                )

    if observations:
        for obs in observations:
            out.append(f'- {obs}')
        out.append('')
    else:
        p('*Insufficient data for automated observations.*')

    p(
        '### Remediation Reference',
        '',
        '| Bottleneck | Tracking | Target |',
        '|---|---|---|',
        '| `POST /rhsm/consumers` latency | foreman#10942 + katello#11701 | Reduce Candlepin synchronisation |',
        '| Excess `GET /compliance` calls | katello#11692 | Cache per consumer UUID |',
        '| Excess `GET /rhsm/status` calls | katello#11696 | Cache globally with short TTL |',
        '| Redundant `GET /rhsm/consumers/:id` | katello#11694 | Eliminate post-create re-fetch |',
        '| Script delivery latency | smart-proxy#935 | Redis/Valkey cache on capsule |',
    )

    return '\n'.join(out)


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

    run_url = args.run_url.rstrip('/')

    # Load all data via the shared pipeline — benefits from records cache,
    # raw log cache, and all future common.py improvements automatically.
    try:
        run_data = load_run_data(
            run_url,
            inventory=args.inventory,
            no_verify_ssl=args.no_verify_ssl,
            cache_dir=args.cache_dir,
            load_records=False,  # only needs sessions, not raw records
        )
    except RuntimeError as exc:
        logging.error('%s', exc)
        sys.exit(1)

    # Satellite-side aggregates from pre-built sessions
    sat_aggregate = _group_sessions(run_data.sat_sessions, 'all runs',
                                    run_data.lb_locations)
    sat_by_level: Dict[Tuple[int, str], rm.Metrics] = {}
    for w in run_data.windows:
        window_sessions = [
            s for s in run_data.sat_sessions
            if s.started_at and w.since_dt <= s.started_at <= w.until_dt
        ]
        for label, m in _group_sessions(window_sessions, f'concurrency={w.level}',
                                        run_data.lb_locations).items():
            sat_by_level[(w.level, label)] = m

    # Capsule-side aggregates from pre-loaded capsule records
    capsule_aggregate: Dict[str, rm.Metrics] = {}
    capsule_by_level: Dict[Tuple[int, str], rm.Metrics] = {}
    for cap_name, records in sorted(run_data.capsule_records.items()):
        all_cap_sessions = rm._pass2_proxy(records, window_sec=300)
        capsule_aggregate[cap_name] = rm._build_metrics(all_cap_sessions, cap_name)
        for w in run_data.windows:
            window_sessions = [
                s for s in all_cap_sessions
                if s.started_at and w.since_dt <= s.started_at <= w.until_dt
            ]
            capsule_by_level[(w.level, cap_name)] = rm._build_metrics(
                window_sessions, f'{cap_name} concurrency={w.level}')

    # Assemble and render
    data = AnalysisData(
        run_url=run_url,
        generated_at=datetime.datetime.utcnow(),
        sat_version=run_data.sat_version,
        katello_version=run_data.katello_version,
        windows=run_data.windows,
        sat_aggregate=sat_aggregate,
        sat_by_level=sat_by_level,
        capsule_aggregate=capsule_aggregate,
        capsule_by_level=capsule_by_level,
        sat_cache_stats=run_data.sat_cache_stats,
        capsule_cache_stats=run_data.capsule_cache_stats,
    )

    print(render_document(data))


if __name__ == '__main__':
    main()
