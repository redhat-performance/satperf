#!/usr/bin/env python3
"""
generate_trace_report.py - Per-connection registration trace report.

Generates a Markdown document modelled on ehelms/foreman-ai-harness
global-registration-api-analysis.md, but for three Satellite topologies
(direct, standalone capsule, load-balanced capsule) at two concurrency
levels: 160 (all succeed) and 480 (failures appear).

For each (topology × concurrency) cell the report shows:
  - One representative sample trace (median-duration session) with every
    API call in order, its timestamp offset, duration, and backend service.
  - Aggregated phase timing table across 10 samples: avg / P50 / P95 per phase.

Usage:
  generate_trace_report.py \\
    --run-url https://workdir-exporter.../run-2026-04-04T12:06:27+00:00/ \\
    --inventory conf/hosts.ini \\
    [--concurrency-low 160] [--concurrency-high 480] \\
    [--samples 10] \\
    [--no-verify-ssl] \\
    --cache-dir "$(python3 -c 'import tempfile; print(tempfile.gettempdir())')/satperf-cache" \\
    > docs/registration-trace-report.md
"""

import argparse
import datetime
import json
import logging
import statistics
import sys
from dataclasses import asdict
from pathlib import Path
from typing import Dict, List, Optional, Tuple

sys.path.insert(0, str(Path(__file__).parent))
import registration_metrics as rm
from common import (
    ConcurrencyWindow,
    RunData,
    configure_ssl,
    load_run_data,
    _topo_category,
    _assign_concurrency,
    _classify_backend,
    _fmt_ts,
    TOPO_DIRECT, TOPO_STANDALONE, TOPO_LB,
)
from trace_registration import (
    ApiCall,
    RegistrationTrace,
    _build_trace,
)


# ---------------------------------------------------------------------------
# Phase definitions
# ---------------------------------------------------------------------------

# A phase groups related API calls by path pattern.
# Order matters — first match wins.
PHASES = [
    ('Script delivery',        ['GET /register']),
    ('Consumer creation',      ['POST /rhsm/consumers']),
    ('Status / cert loop',     ['GET /rhsm/status', 'GET /rhsm/consumers/:id/certificates',
                                 'GET /rhsm/consumers/:id/accessible_content',
                                 'GET /rhsm/consumers/:id/content_overrides',
                                 'GET /rhsm/consumers/:id/release',
                                 'GET /rhsm/']),
    ('Host registration',      ['POST /register']),
    ('Facts update',           ['PUT /rhsm/consumers/:id']),
    ('Compliance polling',     ['GET /rhsm/consumers/:id/compliance']),
    ('Build completion',       ['GET /unattended/built']),
    ('Insights integration',   ['GET /redhat_access/', 'POST /redhat_access/']),
    ('Content download',       ['GET /pulp/']),
]


def _phase_for_call(call: ApiCall) -> str:
    """Return the phase name for a single ApiCall."""
    p = call.path
    for phase_name, patterns in PHASES:
        for pat in patterns:
            # Simple prefix/exact matching
            pat_clean = pat.split(' ', 1)[1] if ' ' in pat else pat
            method_prefix = pat.split(' ', 1)[0] if ' ' in pat else None
            if method_prefix and call.method != method_prefix:
                continue
            # UUID-containing paths: normalise
            if ':id' in pat_clean:
                import re
                pat_re = pat_clean.replace(':id', '[^/]+')
                if re.match(pat_re.replace('/', r'/'), p):
                    return phase_name
            elif p == pat_clean or p.startswith(pat_clean):
                return phase_name
    return 'Other'


# ---------------------------------------------------------------------------
# Sample selection
# ---------------------------------------------------------------------------

def _build_traces_for_group(
        sessions: List[rm.RegistrationSession],
        all_records: Dict,
        capsule_records: Dict[str, Dict],
        topo_label: str,
        window: ConcurrencyWindow,
        n_samples: int,
        window_sec: int = 300) -> List[RegistrationTrace]:
    """Build up to n_samples traces from the median-duration sessions."""
    # Filter sessions to this window and topology
    group = []
    for s in sessions:
        if s.started_at and window.since_dt <= s.started_at <= window.until_dt:
            topo, cap = _topo_category(s, set())  # lb_locations not needed here
            if topo == topo_label:
                group.append(s)

    if not group:
        return []

    # Sort by consumer_create_ms to get spread across the distribution
    group.sort(key=lambda s: s.consumer_create_ms)
    step = max(1, len(group) // n_samples)
    selected = group[::step][:n_samples]

    traces = []
    for s in selected:
        topo, cap = _topo_category(s, set())
        t = _build_trace(s, all_records, capsule_records, cap, topo, window_sec)
        t.concurrency_level = window.level
        traces.append(t)
    return traces


# ---------------------------------------------------------------------------
# Phase statistics aggregation
# ---------------------------------------------------------------------------

def _phase_stats(traces: List[RegistrationTrace]) -> Dict[str, Dict]:
    """Return per-phase statistics across a list of traces.

    Returns: {phase_name: {count: avg, avg_ms: x, p50_ms: x, p95_ms: x,
                            calls_per_session: avg_count}}
    """
    from collections import defaultdict
    phase_durations: Dict[str, List[int]] = defaultdict(list)
    phase_call_counts: Dict[str, List[int]] = defaultdict(list)

    for trace in traces:
        # Accumulate per-phase within this trace
        per_phase_dur: Dict[str, int] = defaultdict(int)
        per_phase_cnt: Dict[str, int] = defaultdict(int)
        for call in trace.calls:
            phase = _phase_for_call(call)
            per_phase_dur[phase] += call.duration_ms
            per_phase_cnt[phase] += 1

        for phase_name, _ in PHASES + [('Other', [])]:
            if phase_name in per_phase_dur:
                phase_durations[phase_name].append(per_phase_dur[phase_name])
                phase_call_counts[phase_name].append(per_phase_cnt[phase_name])

    result = {}
    for phase_name, _ in PHASES + [('Other', [])]:
        durs = phase_durations.get(phase_name, [])
        cnts = phase_call_counts.get(phase_name, [])
        if not durs:
            continue
        durs_s = sorted(durs)
        n = len(durs_s)
        result[phase_name] = {
            'sample_count': n,
            'avg_ms': int(sum(durs_s) / n),
            'p50_ms': durs_s[n // 2],
            'p95_ms': durs_s[min(n - 1, int(n * 0.95))],
            'avg_calls': round(sum(cnts) / n, 1) if cnts else 0,
        }
    return result


# ---------------------------------------------------------------------------
# Sequence diagram rendering
# ---------------------------------------------------------------------------

# Participant labels per topology
_SEQ_PARTICIPANTS = {
    TOPO_DIRECT: [
        ('Client',    'Client'),
        ('Sat',       'Satellite\\n(foreman-proxy + Foreman)'),
        ('CP',        'Candlepin'),
        ('Pulp',      'Pulp'),
    ],
    TOPO_STANDALONE: [
        ('Client',    'Client'),
        ('Cap',       'Capsule\\n(foreman-proxy)'),
        ('Sat',       'Satellite\\n(Foreman)'),
        ('CP',        'Candlepin'),
        ('Pulp',      'Pulp'),
    ],
    TOPO_LB: [
        ('Client',    'Client'),
        ('LB',        'HAProxy'),
        ('Cap',       'Capsule\\n(foreman-proxy)'),
        ('Sat',       'Satellite\\n(Foreman)'),
        ('CP',        'Candlepin'),
        ('Pulp',      'Pulp'),
    ],
}


def _call_to_seq(call: ApiCall, topo: str) -> Optional[tuple]:
    """Map one ApiCall to a (src_id, dst_id, label, duration_ms) tuple.

    Returns None for calls that should be skipped in the diagram
    (e.g., the synthetic rhsm/status summary).
    """
    path = call.path.split('?')[0]
    method = call.method
    ms = call.duration_ms

    # Skip synthetic aggregate entries
    if call.req_id == '(aggregate)':
        n_status = getattr(call, '_status_count', 1)
        if topo == TOPO_DIRECT:
            return ('Client', 'Sat',
                    f'GET /rhsm/status ×N (N={n_status}, shared endpoint)', ms)
        return ('Client', 'Cap',
                f'GET /rhsm/status ×N (N={n_status}, shared endpoint)', ms)

    if call.source_log == 'satellite':
        # Calls logged at the satellite — the "outer" HTTP request the satellite received
        if topo == TOPO_DIRECT:
            outer_src = 'Client'
        else:
            # For capsule topologies, satellite sees the capsule as source for RHSM calls
            # but the client for register calls (capsule forwards POST /register)
            outer_src = 'Cap'

        if call.backend == 'candlepin':
            # Satellite forwards to Candlepin — show inner arrow
            return (outer_src, 'CP', f'{method} {path}', ms)
        elif call.backend == 'foreman':
            return (outer_src, 'Sat', f'{method} {path}', ms)
        elif call.backend == 'pulp':
            return (outer_src, 'Pulp', f'{method} {path}', ms)
        else:
            return (outer_src, 'Sat', f'{method} {path}', ms)

    elif call.source_log.startswith('capsule'):
        # Calls from capsule proxy.log — client↔capsule leg
        if topo == TOPO_LB:
            # Client hits LB first, LB picks a capsule
            if method == 'GET' and '/register' in path:
                return ('Client', 'LB', f'{method} {path}', ms)
            return ('Client', 'LB', f'{method} {path}', ms)
        else:
            return ('Client', 'Cap', f'{method} {path}', ms)

    return None


def _render_topology_comparison(
        direct: RegistrationTrace,
        standalone: RegistrationTrace,
        lb: RegistrationTrace,
        concurrency: int) -> List[str]:
    """Render a single Mermaid diagram comparing the three topologies.

    Uses autonumber and rect blocks to show each topology as a labelled section.
    The key structural difference — the capsule proxy hop for GET/POST /register —
    is highlighted by its presence in standalone/LB but absence in direct.
    """
    def _key_calls(trace: RegistrationTrace, topo: str):
        """Extract the structurally significant calls for a topology."""
        results = []
        for call in trace.calls:
            path = call.path.split('?')[0]
            # Show: GET /register (both proxy and foreman), POST /rhsm/consumers,
            #       POST /register (proxy and foreman), PUT /rhsm/consumers/:id
            if (rm._P_REGISTER.match(path) or
                    rm._P_CONSUMER_CREATE.match(path) or
                    (call.method == 'PUT' and rm._P_CONSUMER_ID.match(path))):
                src, dst, label, ms = _call_to_seq(call, topo) or (None, None, None, 0)
                if src:
                    results.append((src, dst, label, ms, call.backend, call.source_log))
        return results

    lines = [
        '> Structural comparison of the three registration paths. '
        'The capsule proxy hop (GET/POST `/register` via `proxy` backend) '
        'is absent in the Direct topology and present in Standalone and LB.',
        '',
        '```mermaid',
        'sequenceDiagram',
        '    autonumber',
        '    participant Client as Client',
        '    participant LB as HAProxy',
        '    participant Cap as Capsule',
        '    participant Sat as Satellite',
        '    participant CP as Candlepin',
        '',
    ]

    topo_data = [
        (TOPO_DIRECT,     direct,     'Direct — hq-* → Satellite'),
        (TOPO_STANDALONE, standalone, 'Standalone capsule — a-*/b-* → capsule → Satellite'),
        (TOPO_LB,         lb,         'Load-balanced capsule — c-* → HAProxy → capsule → Satellite'),
    ]

    for topo, trace, label in topo_data:
        if not trace:
            continue
        lines.append(f'    rect rgb(240, 248, 255)')
        lines.append(f'        Note over Client,CP: {label} (total {trace.total_duration_ms:,} ms)')
        for src, dst, call_label, ms, backend, source in _key_calls(trace, topo):
            call_label_short = call_label if len(call_label) < 50 else call_label[:47] + '…'
            note = f' ({ms:,} ms)' if ms else ''
            lines.append(f'        {src}->>{dst}: {call_label_short}{note}')
            lines.append(f'        {dst}-->>{src}: HTTP 2xx')
        lines.append('    end')
        lines.append('')

    lines.append('```')
    return lines


def _render_sequence_diagram(trace: RegistrationTrace, topo: str,
                              concurrency: int) -> List[str]:
    """Render a Mermaid sequenceDiagram for one registration trace."""
    participants = _SEQ_PARTICIPANTS.get(topo, _SEQ_PARTICIPANTS[TOPO_DIRECT])

    lines = [
        f'> UUID: `{trace.uuid}` — Total: **{trace.total_duration_ms:,} ms**',
        '',
        '```mermaid',
        'sequenceDiagram',
        f'    %% {_TOPO_DISPLAY[topo]} — concurrency {concurrency}',
    ]
    for pid, label in participants:
        lines.append(f'    participant {pid} as {label}')
    lines.append('')

    for call in trace.calls:
        arrow = _call_to_seq(call, topo)
        if not arrow:
            continue
        src, dst, label, ms = arrow
        label_short = label if len(label) < 60 else label[:57] + '…'
        lines.append(f'    {src}->>{dst}: {label_short}')
        if ms:
            lines.append(f'    Note right of {dst}: {ms:,} ms')
        lines.append(f'    {dst}-->>{src}: HTTP {call.status}')
        lines.append('')

    lines.append('```')
    return lines


# ---------------------------------------------------------------------------
# Markdown rendering helpers
# ---------------------------------------------------------------------------

def _ts_offset(call_ts: str, base_ts: str) -> str:
    """Return '+HH:MM:SS.mmm' offset of call_ts from base_ts."""
    try:
        fmt = '%Y-%m-%dT%H:%M:%S.%f'
        t1 = datetime.datetime.strptime(call_ts, fmt)
        t0 = datetime.datetime.strptime(base_ts, fmt)
        delta = (t1 - t0).total_seconds()
        sign = '+' if delta >= 0 else '-'
        delta = abs(delta)
        h = int(delta // 3600)
        m = int((delta % 3600) // 60)
        s = delta % 60
        return f'{sign}{h:02d}:{m:02d}:{s:06.3f}'
    except Exception:
        return '?'


def _pick_representative(traces: List[RegistrationTrace]) -> RegistrationTrace:
    """Return the median-duration trace that has a reasonably complete call set.

    Prefers traces with UUID-keyed calls (compliance, consumer GET/PUT) present,
    which indicates the audit-log UUID attribution was successful and the full
    session flow was captured.  Falls back to the plain median if no trace meets
    the threshold.
    """
    # UUID-keyed paths contain the consumer UUID (36-char hex)
    import re as _re
    _uuid_re = _re.compile(r'[0-9a-f]{8}-[0-9a-f]{4}')

    def _uuid_call_count(t: RegistrationTrace) -> int:
        return sum(1 for c in t.calls if _uuid_re.search(c.path))

    # Prefer traces with at least 3 UUID-keyed calls (compliance, consumer GET, PUT)
    full = [t for t in traces if _uuid_call_count(t) >= 3 and t.success]
    pool = full if full else [t for t in traces if t.success] or traces
    pool.sort(key=lambda t: t.total_duration_ms)
    return pool[len(pool) // 2]


def _render_sample_trace(trace: RegistrationTrace) -> List[str]:
    """Render one trace as a Markdown table of API calls."""
    lines = [
        f'UUID: `{trace.uuid}`  ',
        f'Total: **{trace.total_duration_ms:,} ms**  ',
        f'Result: {"✓ success" if trace.success else "✗ " + trace.error_type}',
        '',
        '| Offset | Method | Path | Status | Duration | Backend |',
        '|---|---|---|---:|---:|---|',
    ]
    # Offset from the first call in the trace (should be GET /register),
    # not from t0 (POST /rhsm/consumers), so the trace reads left-to-right
    # from the client's point of view.
    base = trace.calls[0].ts if trace.calls else trace.started_at
    for call in trace.calls:
        offset = _ts_offset(call.ts, base)
        lines.append(
            f'| `{offset}` | `{call.method}` | `{call.path_raw}` '
            f'| {call.status} | {call.duration_ms:,} ms | {call.backend} |'
        )
    return lines


def _render_phase_table(stats: Dict[str, Dict]) -> List[str]:
    """Render phase statistics as a Markdown table."""
    if not stats:
        return ['*No trace data available for this cell.*']
    lines = [
        '| Phase | Avg calls | Avg ms | P50 ms | P95 ms |',
        '|---|---:|---:|---:|---:|',
    ]
    for phase_name, _ in PHASES + [('Other', [])]:
        if phase_name not in stats:
            continue
        s = stats[phase_name]
        lines.append(
            f'| {phase_name} | {s["avg_calls"]} | {s["avg_ms"]:,} '
            f'| {s["p50_ms"]:,} | {s["p95_ms"]:,} |'
        )
    return lines


# ---------------------------------------------------------------------------
# Document rendering
# ---------------------------------------------------------------------------

_TOPO_DISPLAY = {
    TOPO_DIRECT:     'Direct (Satellite)',
    TOPO_STANDALONE: 'Standalone Capsule',
    TOPO_LB:         'Load-Balanced Capsule',
}

_TOPO_DESC = {
    TOPO_DIRECT: (
        'Container hosts (`hq-*`) connect directly to the Satellite. '
        'Foreman-proxy handles script delivery; all RHSM calls go to Candlepin '
        'via Katello.'
    ),
    TOPO_STANDALONE: (
        'Container hosts (`a-*`, `b-*`) connect to a dedicated Capsule node '
        'with no load balancer. The Capsule\'s foreman-proxy serves the '
        'registration script (possibly from cache) and proxies POST /register '
        'to the Satellite. RHSM calls are forwarded via the Capsule\'s RHSM '
        'proxy and appear in `production.log` with the Capsule\'s source IP.'
    ),
    TOPO_LB: (
        'Container hosts (`c-*`) connect to an HAProxy front-end that '
        'distributes across two Capsule nodes (c-1, c-2). Individual Capsule '
        'node metrics are shown separately in the capsule-side section.'
    ),
}


def render_document(
        run_data: RunData,
        traces_by_cell: Dict[Tuple[str, int], List[RegistrationTrace]],
        levels: List[int],
        n_samples: int) -> str:
    out = []

    def h(level: int, text: str):
        out.append(f'\n{"#" * level} {text}\n')

    def p(*lines):
        for line in lines:
            out.append(line)
        out.append('')

    generated = datetime.datetime.utcnow().strftime('%Y-%m-%d %H:%M UTC')
    h(1, 'Satellite Registration Trace Analysis')
    p(
        f'**Generated:** {generated}  ',
        f'**Source:** {run_data.run_url}  ',
        f'**Satellite:** {run_data.sat_version} &nbsp; '
        f'**Katello:** {run_data.katello_version}',
    )

    # ------------------------------------------------------------------ §1
    h(2, '1. Overview')
    p(
        'This document traces individual host registrations end-to-end, showing '
        'every API call made during the `subscription-manager register` workflow. '
        'It covers three Satellite network topologies at two concurrency levels:',
        '',
        f'- **Concurrency {levels[0]}** — server fully absorbs all first-try '
        f'registrations (100% first-try success rate)',
        f'- **Concurrency {levels[1]}** — server is saturated; client-side read '
        f'timeouts begin to appear',
        '',
        'For each *(topology × concurrency)* combination the report shows:',
        '1. A representative sample trace (median-duration session) with every API '
        '   call listed in chronological order.',
        '2. Aggregated phase timing statistics across ' + str(n_samples) + ' samples.',
    )

    # ------------------------------------------------------------------ §2
    h(2, '2. Test Environment')
    p(
        '| Component | Details |',
        '|---|---|',
        f'| Satellite | {run_data.sat_version} |',
        f'| Katello | {run_data.katello_version} |',
        '| OS | RHEL 9 |',
        '| Direct topology | `containerhost-hq-1`, `hq-2` → Satellite |',
        '| Standalone capsule | `containerhost-a-*`, `b-*` → capsule-a-1, capsule-b-1 |',
        '| LB capsule | `containerhost-c-*` → HAProxy → capsule-c-1 / capsule-c-2 |',
        f'| Concurrency levels analysed | {", ".join(str(l) for l in levels)} |',
        f'| Samples per cell | {n_samples} |',
    )

    # ------------------------------------------------------------------ §3
    h(2, '3. Registration Workflow (Reference Sequence)')
    p(
        'All three topologies share the same logical phases. Timings differ because '
        'standalone and LB capsule registrations add a capsule proxy hop for the '
        'script delivery and the `POST /register` leg.',
        '',
        '```',
        'Phase 1 — Script delivery',
        '  Client  ──GET /register──►  [Capsule | Satellite] foreman-proxy',
        '          ◄── registration script (bash) ──────────',
        '',
        'Phase 2 — Consumer creation (longest operation)',
        '  Client  ──POST /rhsm/consumers──►  [Capsule RHSM proxy →] Satellite',
        '                                       └─► Candlepin (≈3–20 s)',
        '',
        'Phase 3 — Status / certificate loop',
        '  Client  ──GET /rhsm/status ×N ──────►  Candlepin (12–23 calls avg)',
        '  Client  ──GET /rhsm/.../certificates►  Candlepin',
        '  Client  ──GET .../accessible_content►  Candlepin',
        '  Client  ──GET .../content_overrides ►  Candlepin',
        '',
        'Phase 4 — Host registration',
        '  Client  ──POST /register──►  [Capsule →] Satellite (Foreman host record)',
        '',
        'Phase 5 — Facts update',
        '  Client  ──PUT /rhsm/consumers/:id──►  Candlepin',
        '',
        'Phase 6 — Compliance polling',
        '  Client  ──GET .../compliance ×N──►  Candlepin (22+ calls avg)',
        '',
        'Phase 7 — Build completion (if enabled)',
        '  Client  ──GET /unattended/built──►  Foreman',
        '```',
    )

    # ------------------------------------------------------------------ §4 Sequence diagrams
    h(2, f'4. Sequence Diagrams by Topology (Concurrency {levels[0]})')
    p(
        'The following Mermaid sequence diagrams are generated from the median-duration '
        f'representative trace at concurrency {levels[0]}, showing every API call in '
        'chronological order. Comparing the three topologies reveals where the '
        'capsule proxy hop adds latency and which calls are shared vs. unique to each path.',
    )

    rep = {}  # topo → representative trace, reused for comparison diagram
    for topo in [TOPO_DIRECT, TOPO_STANDALONE, TOPO_LB]:
        topo_display = _TOPO_DISPLAY[topo]
        traces = traces_by_cell.get((topo, levels[0]), [])
        if not traces:
            h(3, topo_display)
            p('*No traces available for this topology.*')
            continue
        rep[topo] = _pick_representative(traces)

        h(3, topo_display)
        out.extend(_render_sequence_diagram(rep[topo], topo, levels[0]))
        out.append('')

    # Topology comparison — single diagram showing structural differences
    if len(rep) >= 2:
        h(3, 'Topology Comparison')
        p(
            'All three paths in one diagram. The capsule proxy hop '
            '(`GET`/`POST /register` via `proxy` backend) is the structural '
            'difference between Direct and the capsule topologies.'
        )
        out.extend(_render_topology_comparison(
            rep.get(TOPO_DIRECT),
            rep.get(TOPO_STANDALONE),
            rep.get(TOPO_LB),
            levels[0],
        ))
        out.append('')

    # ------------------------------------------------------------------ §5+
    for level in levels:
        h(2, f'{"5" if level == levels[0] else "6"}. '
             f'Concurrency {level} — '
             f'{"all succeed" if level == levels[0] else "saturation / failures"}')

        for topo in [TOPO_DIRECT, TOPO_STANDALONE, TOPO_LB]:
            topo_display = _TOPO_DISPLAY[topo]
            traces = traces_by_cell.get((topo, level), [])

            h(3, topo_display)
            p(_TOPO_DESC[topo])

            if not traces:
                p('*No traces available for this topology at this concurrency level.*')
                continue

            # Representative trace (median by total_duration_ms)
            representative = _pick_representative(traces)

            h(4, 'Representative Trace (median duration)')
            out.extend(_render_sample_trace(representative))
            out.append('')

            # Phase statistics across all samples
            stats = _phase_stats(traces)
            h(4, f'Phase Timing — {len(traces)} samples')
            out.extend(_render_phase_table(stats))
            out.append('')

            # Error analysis for the high-concurrency cell
            if level == levels[1]:
                errors = [t for t in traces if not t.success]
                if errors:
                    h(4, 'Failure Analysis')
                    p(
                        f'**{len(errors)}** of **{len(traces)}** sampled registrations '
                        f'failed at this concurrency level.',
                        '',
                        '| Error Type | Count |',
                        '|---|---:|',
                    )
                    from collections import Counter
                    for etype, count in Counter(t.error_type for t in errors).most_common():
                        out.append(f'| {etype} | {count} |')
                    out.append('')
                    p(
                        '> The dominant failure mode at this concurrency is a **client-side '
                        'read timeout**: subscription-manager completes `POST /rhsm/consumers` '
                        '(consumer UUID is assigned on the server) but a subsequent RHSM call '
                        '(compliance poll or certificate download) exceeds the client timeout. '
                        'The satellite has already registered the host; the failure is purely '
                        'a network-layer timeout on the client side.',
                    )

    # ------------------------------------------------------------------ §7
    h(2, f'7. Phase Timing Comparison: {levels[0]} vs {levels[1]} Concurrent')
    p(
        f'Average duration per phase at concurrency {levels[0]} vs {levels[1]}, '
        f'showing how server load affects each step.',
    )

    for topo in [TOPO_DIRECT, TOPO_STANDALONE, TOPO_LB]:
        topo_display = _TOPO_DISPLAY[topo]
        low_stats = _phase_stats(traces_by_cell.get((topo, levels[0]), []))
        high_stats = _phase_stats(traces_by_cell.get((topo, levels[1]), []))

        if not low_stats and not high_stats:
            continue

        h(3, topo_display)
        out.append(f'| Phase | {levels[0]} avg ms | {levels[1]} avg ms | Δ ms | Δ % |')
        out.append('|---|---:|---:|---:|---:|')

        all_phases = [p for p, _ in PHASES if p in low_stats or p in high_stats]
        for phase_name in all_phases:
            lo = low_stats.get(phase_name, {}).get('avg_ms', 0)
            hi = high_stats.get(phase_name, {}).get('avg_ms', 0)
            delta = hi - lo
            sign = '+' if delta >= 0 else ''
            pct = f'{sign}{delta / lo * 100:.0f}%' if lo else 'n/a'
            out.append(f'| {phase_name} | {lo:,} | {hi:,} | {sign}{delta:,} | {pct} |')
        out.append('')

    return '\n'.join(out)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument('--run-url', required=True, metavar='URL')
    parser.add_argument('--inventory', metavar='FILE')
    parser.add_argument('--concurrency-low', type=int, default=160, metavar='N',
                        help='Lower concurrency level (all succeed, default: 160)')
    parser.add_argument('--concurrency-high', type=int, default=480, metavar='N',
                        help='Higher concurrency level (failures, default: 480)')
    parser.add_argument('--samples', type=int, default=10, metavar='N',
                        help='Sample traces per (topology, concurrency) cell (default: 10)')
    parser.add_argument('--no-verify-ssl', action='store_true')
    parser.add_argument('--cache-dir', metavar='DIR',
                        help='Cache extracted log files here; subsequent runs skip '
                             'the download+decompress step (~10 min → <30 s)')
    parser.add_argument('--download-only', action='store_true',
                        help='Populate the cache and exit — no report generated. '
                             'Useful to pre-fetch data on a fast network.')
    parser.add_argument('-v', '--verbose', action='store_true')
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format='%(levelname)s: %(message)s', stream=sys.stderr,
    )

    configure_ssl(args.no_verify_ssl)

    run_data = load_run_data(
        args.run_url,
        inventory=args.inventory,
        no_verify_ssl=args.no_verify_ssl,
        cache_dir=args.cache_dir,
    )

    if args.download_only:
        logging.info('--download-only: cache populated, exiting.')
        sys.exit(0)

    levels = [args.concurrency_low, args.concurrency_high]

    # Find the windows for our target levels
    level_windows: Dict[int, ConcurrencyWindow] = {
        w.level: w for w in run_data.windows if w.level in levels
    }
    for lvl in levels:
        if lvl not in level_windows:
            logging.error('Concurrency level %d not found in measurement.log', lvl)
            logging.error('Available levels: %s', [w.level for w in run_data.windows])
            sys.exit(1)

    # Build traces for each (topology, level) cell
    traces_by_cell: Dict[Tuple[str, int], List[RegistrationTrace]] = {}

    for topo in [TOPO_DIRECT, TOPO_STANDALONE, TOPO_LB]:
        for level in levels:
            window = level_windows[level]

            # Filter sessions to this window and topology
            group = []
            for s in run_data.sat_sessions:
                if not (s.started_at and window.since_dt <= s.started_at <= window.until_dt):
                    continue
                s_topo, _ = _topo_category(s, run_data.lb_locations)
                if s_topo == topo:
                    group.append(s)

            if not group:
                logging.warning('No sessions for topology=%s level=%d', topo, level)
                continue

            # Select up to n_samples spread across the duration distribution
            group.sort(key=lambda s: s.consumer_create_ms)
            step = max(1, len(group) // args.samples)
            selected = group[::step][:args.samples]
            logging.info('Building %d traces for %s @ %d', len(selected), topo, level)

            traces = []
            for s in selected:
                _, cap = _topo_category(s, run_data.lb_locations)
                t = _build_trace(s, run_data.sat_records, run_data.capsule_records,
                                 cap, topo, window_sec=300,
                                 uuid_index=run_data.uuid_index,
                                 path_indexes=run_data.path_indexes)
                t.concurrency_level = level
                traces.append(t)

            traces_by_cell[(topo, level)] = traces
            logging.info('Built %d traces for %s @ %d', len(traces), topo, level)

    doc = render_document(run_data, traces_by_cell, levels, args.samples)
    print(doc)


if __name__ == '__main__':
    main()
