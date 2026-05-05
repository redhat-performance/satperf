"""
analyze_batch_dynamics.py — Per-level drain curve analysis.

Correlates Puma backlog, PG wait events, GC stats, session latencies,
and network connections at second-by-second resolution to diagnose
non-linear registration performance (e.g. the 912 bump / 1520 recovery).

Usage:
  python3 analyze_batch_dynamics.py \\
    --cache-dir /tmp/satperf-cache-red --build 1541 \\
    --workdir-base https://workdir-exporter-.../workspace/Sat_Red \\
    --no-verify-ssl --levels 760 912 1064 1520
"""

import argparse
import datetime
import logging
import re
import sys
from pathlib import Path
from typing import List

sys.path.insert(0, str(Path(__file__).parent))
import registration_metrics as rm
from common import (
    ConcurrencyWindow,
    _assign_concurrency,
    configure_ssl,
    parse_measurement_log,
)
from monitoring_data import resolve_build_to_run_url

log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Monitor log parsers
# ---------------------------------------------------------------------------


def _parse_tsv(path: str, fields: List[str]) -> List[dict]:
    """Generic TSV parser: skip # comments, split by whitespace."""
    result = []
    try:
        with open(path) as f:
            for line in f:
                if line.startswith("#"):
                    continue
                parts = line.strip().split()
                if len(parts) >= len(fields):
                    entry = {}
                    for i, name in enumerate(fields):
                        entry[name] = float(parts[i]) if name == "ts" else int(parts[i])
                    result.append(entry)
    except FileNotFoundError:
        log.warning("Monitor file not found: %s", path)
    return result


def _parse_puma_log(path: str) -> List[dict]:
    return _parse_tsv(path, ["ts", "backlog", "busy", "capacity", "requests"])


def _parse_pg_summary(path: str) -> List[dict]:
    return _parse_tsv(
        path,
        ["ts", "active", "idle", "wait_io", "wait_lock",
         "wait_lwlock", "wait_client", "foreman", "candlepin"],
    )


def _parse_tomcat_log(path: str) -> List[dict]:
    return _parse_tsv(path, ["ts", "threads"])


def _parse_net_log(path: str) -> List[dict]:
    # Support both old (5-col) and new (6-col with candlepin_tw) formats
    new_fields = ["ts", "httpd", "candlepin", "candlepin_tw", "postgres", "puma_sock"]
    result = _parse_tsv(path, new_fields)
    if result:
        return result
    # Fall back to old format (no TIME_WAIT column)
    old_fields = ["ts", "httpd", "candlepin", "postgres", "puma_sock"]
    old_result = _parse_tsv(path, old_fields)
    for entry in old_result:
        entry["candlepin_tw"] = 0
    return old_result


_RE_GC = re.compile(
    r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}) .* "
    r"GC pid=(\d+) count=(\d+) major=(\d+) "
    r"heap_live=(\d+) heap_free=(\d+) "
    r"malloc=(\d+) oldmalloc=(\d+) "
    r"total_time=([\d.]+)s"
)


def _parse_gc_log(path: str) -> List[dict]:
    result = []
    with open(path) as f:
        for line in f:
            m = _RE_GC.match(line)
            if m:
                ts = datetime.datetime.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S")
                result.append({
                    "ts": ts.replace(tzinfo=datetime.timezone.utc).timestamp(),
                    "ts_dt": ts,
                    "pid": m.group(2),
                    "count": int(m.group(3)),
                    "major": int(m.group(4)),
                    "heap_live": int(m.group(5)),
                    "heap_free": int(m.group(6)),
                    "malloc": int(m.group(7)),
                    "oldmalloc": int(m.group(8)),
                    "total_time": float(m.group(9)),
                })
    return result


# ---------------------------------------------------------------------------
# Session parsing with ActiveRecord / Allocations
# ---------------------------------------------------------------------------

_RE_COMPLETED_FULL = re.compile(
    r"Completed (\d+) .* in (\d+)ms"
    r"(?:.*ActiveRecord: ([\d.]+)ms)?"
    r"(?:.*Allocations: (\d+))?"
)


def _parse_sessions_with_ar(path: str):
    """Parse production.log → sessions + AR times + allocations."""
    ar_times, allocs = {}, {}
    with open(path) as f:
        lines = f.readlines()
    for line in lines:
        m = rm._RE_LOG_LINE.match(line.rstrip("\n"))
        if not m:
            continue
        req_id, body = m.group(2), m.group(3)
        c = _RE_COMPLETED_FULL.match(body)
        if c:
            if c.group(3):
                ar_times[req_id] = float(c.group(3))
            if c.group(4):
                allocs[req_id] = int(c.group(4))
    records = rm._pass1(lines)
    sessions = rm._pass2(records)
    return sessions, ar_times, allocs


# ---------------------------------------------------------------------------
# Time bucketing
# ---------------------------------------------------------------------------


def _bucket_monitor(data: List[dict], since: float, until: float,
                    bucket_size: int = 10) -> List[dict]:
    """Group monitor samples into time buckets."""
    buckets = []
    t = since
    while t < until:
        t_end = min(t + bucket_size, until)
        samples = [d for d in data if t <= d["ts"] < t_end]
        if samples:
            bucket = {"t": t - since, "t_end": t_end - since, "n": len(samples)}
            # Aggregate each numeric field
            for key in samples[0]:
                if key == "ts":
                    continue
                vals = [s[key] for s in samples]
                if isinstance(vals[0], (int, float)):
                    bucket[f"{key}_avg"] = sum(vals) / len(vals)
                    bucket[f"{key}_max"] = max(vals)
                    bucket[f"{key}_min"] = min(vals)
            # Puma throughput: request delta
            if "requests" in samples[0] and len(samples) >= 2:
                bucket["throughput"] = (
                    (samples[-1]["requests"] - samples[0]["requests"])
                    / (samples[-1]["ts"] - samples[0]["ts"])
                ) if samples[-1]["ts"] > samples[0]["ts"] else 0
            buckets.append(bucket)
        else:
            buckets.append({"t": t - since, "t_end": t_end - since, "n": 0})
        t = t_end
    return buckets


def _dt_to_utc_epoch(dt: datetime.datetime) -> float:
    """Convert a naive-UTC datetime to a UTC epoch float."""
    return dt.replace(tzinfo=datetime.timezone.utc).timestamp()


def _bucket_sessions(sessions: List[rm.RegistrationSession],
                     since: float, until: float,
                     bucket_size: int = 10) -> List[dict]:
    """Group sessions by started_at into time buckets."""
    buckets = []
    t = since
    while t < until:
        t_end = min(t + bucket_size, until)
        bucket_sessions = [
            s for s in sessions
            if s.started_at and t <= _dt_to_utc_epoch(s.started_at) < t_end
        ]
        cc_vals = [s.consumer_create_ms for s in bucket_sessions if s.consumer_create_ms > 0]
        status_vals = [s.status_calls for s in bucket_sessions]
        comp_vals = [s.compliance_calls for s in bucket_sessions]

        bucket = {
            "t": t - since,
            "count": len(bucket_sessions),
        }
        if cc_vals:
            cc_sorted = sorted(cc_vals)
            bucket["cc_p50"] = cc_sorted[len(cc_sorted) // 2]
        if status_vals:
            bucket["status_avg"] = sum(status_vals) / len(status_vals)
        if comp_vals:
            bucket["comp_avg"] = sum(comp_vals) / len(comp_vals)

        buckets.append(bucket)
        t = t_end
    return buckets


def _bucket_gc(gc_data: List[dict], since: float, until: float,
               bucket_size: int = 10) -> List[dict]:
    """Group GC entries into time buckets."""
    buckets = []
    t = since
    while t < until:
        t_end = min(t + bucket_size, until)
        samples = [g for g in gc_data if t <= g["ts"] < t_end]
        bucket = {"t": t - since, "count": len(samples)}
        if samples:
            bucket["heap_free_avg"] = sum(g["heap_free"] for g in samples) / len(samples)
            bucket["heap_free_min"] = min(g["heap_free"] for g in samples)
            bucket["total_time_avg"] = sum(g["total_time"] for g in samples) / len(samples)
            # GC rate: count delta per unique PID
            pids = set(g["pid"] for g in samples)
            deltas = []
            for pid in pids:
                pid_s = sorted([g for g in samples if g["pid"] == pid], key=lambda g: g["ts"])
                if len(pid_s) >= 2:
                    deltas.append(pid_s[-1]["count"] - pid_s[0]["count"])
            bucket["gc_per_worker"] = sum(deltas) / len(deltas) if deltas else 0
        buckets.append(bucket)
        t = t_end
    return buckets


# ---------------------------------------------------------------------------
# Per-level analysis
# ---------------------------------------------------------------------------


def _analyze_level(w: ConcurrencyWindow,
                   sessions: List[rm.RegistrationSession],
                   puma: List[dict], pg: List[dict],
                   tomcat: List[dict], net: List[dict],
                   gc: List[dict],
                   bucket_size: int = 10) -> dict:
    """Produce full analysis for one concurrency level."""
    level_sessions = [s for s in sessions if _assign_concurrency(s, [w]) == w.level]

    puma_buckets = _bucket_monitor(puma, w.since, w.until, bucket_size)
    pg_buckets = _bucket_monitor(pg, w.since, w.until, bucket_size)
    tomcat_buckets = _bucket_monitor(tomcat, w.since, w.until, bucket_size)
    net_buckets = _bucket_monitor(net, w.since, w.until, bucket_size)
    session_buckets = _bucket_sessions(level_sessions, w.since, w.until, bucket_size)
    gc_buckets = _bucket_gc(gc, w.since, w.until, bucket_size)

    # Summary metrics
    puma_in_window = [p for p in puma if w.since <= p["ts"] <= w.until]
    peak_backlog = max((p["backlog"] for p in puma_in_window), default=0)

    # Time to clear backlog
    time_to_clear = 0
    for p in puma_in_window:
        if p["backlog"] > 0:
            time_to_clear = p["ts"] - w.since
    # that gives last time with backlog > 0

    # Drain rate
    backlog_samples = [p for p in puma_in_window if p["backlog"] > 0]
    if len(backlog_samples) >= 2:
        drain_duration = backlog_samples[-1]["ts"] - backlog_samples[0]["ts"]
        drain_reqs = backlog_samples[-1]["requests"] - backlog_samples[0]["requests"]
        drain_rate = drain_reqs / drain_duration if drain_duration > 0 else 0
    else:
        drain_rate = 0

    # Early vs late split
    level_sessions.sort(key=lambda s: s.started_at or datetime.datetime.max)
    mid = len(level_sessions) // 2
    early = level_sessions[:mid]
    late = level_sessions[mid:]

    def _p50(vals):
        if not vals:
            return 0
        s = sorted(vals)
        return s[len(s) // 2]

    early_cc = _p50([s.consumer_create_ms for s in early if s.consumer_create_ms > 0])
    late_cc = _p50([s.consumer_create_ms for s in late if s.consumer_create_ms > 0])
    early_status = sum(s.status_calls for s in early) / len(early) if early else 0
    late_status = sum(s.status_calls for s in late) / len(late) if late else 0

    # Phase throughput (from Puma req deltas)
    def _phase_throughput(start_s, end_s):
        phase = [p for p in puma_in_window if start_s <= (p["ts"] - w.since) < end_s]
        if len(phase) >= 2:
            dt = phase[-1]["ts"] - phase[0]["ts"]
            dr = phase[-1]["requests"] - phase[0]["requests"]
            return dr / dt if dt > 0 else 0
        return 0

    phase1 = _phase_throughput(0, 60)
    phase3 = _phase_throughput(180, 360)
    accel = phase3 / phase1 if phase1 > 0 else 0

    return {
        "level": w.level,
        "pass_pct": w.success_pct,
        "passed": w.passed,
        "total": w.level,
        "window_s": w.window_s,
        "sessions": len(level_sessions),
        "peak_backlog": peak_backlog,
        "time_to_clear": time_to_clear,
        "drain_rate": drain_rate,
        "early_cc_p50": early_cc,
        "late_cc_p50": late_cc,
        "early_status": early_status,
        "late_status": late_status,
        "phase1_throughput": phase1,
        "phase3_throughput": phase3,
        "throughput_accel": accel,
        "puma_buckets": puma_buckets,
        "pg_buckets": pg_buckets,
        "tomcat_buckets": tomcat_buckets,
        "net_buckets": net_buckets,
        "session_buckets": session_buckets,
        "gc_buckets": gc_buckets,
    }


# ---------------------------------------------------------------------------
# Markdown rendering
# ---------------------------------------------------------------------------


def _pct(old, new):
    if old == 0:
        return "-"
    d = (new - old) / old * 100
    return f"{d:+.0f}%"


def render_summary(analyses: List[dict]) -> str:
    lines = [
        "## Summary",
        "",
        "| Level | Pass% | Peak BL | Clear(s) | Drain r/s"
        " | Early P50 | Late P50 | Δ Late"
        " | Ph1 r/s | Ph3 r/s | Accel |",
        "|---:|---:|---:|---:|---:"
        "|---:|---:|---:"
        "|---:|---:|---:|",
    ]
    for a in analyses:
        lines.append(
            f"| {a['level']} | {a['pass_pct']:.0f}%"
            f" | {a['peak_backlog']}"
            f" | {a['time_to_clear']:.0f}"
            f" | {a['drain_rate']:.0f}"
            f" | {a['early_cc_p50']:,}ms"
            f" | {a['late_cc_p50']:,}ms"
            f" | **{_pct(a['early_cc_p50'], a['late_cc_p50'])}**"
            f" | {a['phase1_throughput']:.0f}"
            f" | {a['phase3_throughput']:.0f}"
            f" | {a['throughput_accel']:.1f}x |"
        )
    lines.append("")
    return "\n".join(lines)


def render_drain_curve(a: dict) -> str:
    lines = [
        f"### Level {a['level']} ({a['pass_pct']:.0f}%"
        f" — {a['passed']}/{a['total']},"
        f" peak backlog {a['peak_backlog']})",
        "",
    ]

    # Build aligned table from all bucket sources
    puma = {int(b["t"]): b for b in a["puma_buckets"]}
    pg = {int(b["t"]): b for b in a["pg_buckets"]}
    sess = {int(b["t"]): b for b in a["session_buckets"]}
    gc = {int(b["t"]): b for b in a["gc_buckets"]}
    net = {int(b["t"]): b for b in a["net_buckets"]}

    all_times = sorted(set(list(puma.keys()) + list(pg.keys()) + list(sess.keys())))
    if not all_times:
        lines.append("*(no monitor data for this level)*\n")
        return "\n".join(lines)

    lines.append(
        "| Bucket | Backlog | Busy | Thrput"
        " | PG Act | PG IO | PG Lock"
        " | Sessions | CC P50 | Stat/reg"
        " | GC/wkr | HeapFree"
        " | CP est | CP tw | httpd | puma_sk |"
    )
    lines.append(
        "|---:|---:|---:|---:"
        "|---:|---:|---:"
        "|---:|---:|---:"
        "|---:|---:"
        "|---:|---:|---:|---:|"
    )

    for t in all_times:
        p = puma.get(t, {})
        g = pg.get(t, {})
        s = sess.get(t, {})
        gc_b = gc.get(t, {})
        n = net.get(t, {})

        backlog = f"{p.get('backlog_max', 0)}" if p.get("n", 0) else "-"
        busy = f"{p.get('busy_avg', 0):.0f}" if p.get("n", 0) else "-"
        thrput = f"{p.get('throughput', 0):.0f}" if p.get("throughput") else "-"
        pg_act = f"{g.get('active_avg', 0):.0f}" if g.get("n", 0) else "-"
        pg_io = f"{g.get('wait_io_avg', 0):.0f}" if g.get("n", 0) else "-"
        pg_lock = f"{g.get('wait_lock_avg', 0):.0f}" if g.get("n", 0) else "-"
        s_count = f"{s.get('count', 0)}" if s else "-"
        cc_p50 = f"{s.get('cc_p50', 0):,}" if s.get("cc_p50") else "-"
        stat = f"{s.get('status_avg', 0):.1f}" if s.get("status_avg") is not None else "-"
        gc_wkr = f"{gc_b.get('gc_per_worker', 0):.1f}" if gc_b.get("count", 0) else "-"
        hfree = f"{gc_b.get('heap_free_min', 0)}" if gc_b.get("count", 0) else "-"
        cp_est = f"{n.get('candlepin_avg', 0):.0f}" if n.get("n", 0) else "-"
        cp_tw = f"{n.get('candlepin_tw_avg', 0):.0f}" if n.get("n", 0) else "-"
        httpd = f"{n.get('httpd_avg', 0):.0f}" if n.get("n", 0) else "-"
        psk = f"{n.get('puma_sock_avg', 0):.0f}" if n.get("n", 0) else "-"

        lines.append(
            f"| {t}s | {backlog} | {busy} | {thrput}"
            f" | {pg_act} | {pg_io} | {pg_lock}"
            f" | {s_count} | {cc_p50} | {stat}"
            f" | {gc_wkr} | {hfree}"
            f" | {cp_est} | {cp_tw} | {httpd} | {psk} |"
        )

    lines.append("")
    return "\n".join(lines)


def render_document(build: int, analyses: List[dict]) -> str:
    sections = [
        f"# Batch Dynamics Analysis — Build {build}",
        "",
        render_summary(analyses),
    ]
    for a in analyses:
        sections.append(render_drain_curve(a))
    return "\n".join(sections)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Analyze registration batch dynamics with drain curves.")
    parser.add_argument("--cache-dir", required=True,
                        help="Path to cached build data")
    parser.add_argument("--build", type=int, required=True,
                        help="Build number")
    parser.add_argument("--workdir-base", required=True,
                        help="Workdir-exporter base URL")
    parser.add_argument("--no-verify-ssl", action="store_true")
    parser.add_argument("--levels", type=int, nargs="*",
                        help="Concurrency levels to analyze (default: all)")
    parser.add_argument("--bucket-size", type=int, default=10,
                        help="Time bucket size in seconds (default: 10)")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(levelname)s: %(message)s",
        stream=sys.stderr,
    )

    configure_ssl(args.no_verify_ssl)

    build_dir = Path(args.cache_dir) / f"build-{args.build}"
    prod_log = build_dir / "production.log"
    mon_dir = build_dir / "reg-monitor"

    if not prod_log.exists():
        log.error("production.log not found at %s", prod_log)
        sys.exit(1)

    # Load concurrency windows
    run_url = resolve_build_to_run_url(args.workdir_base, args.build)
    windows, _, _ = parse_measurement_log(run_url)

    if args.levels:
        windows = [w for w in windows if w.level in args.levels]

    log.info("Analyzing %d levels for build %d", len(windows), args.build)

    # Load all data sources
    log.info("Parsing production.log...")
    sessions, _, _ = _parse_sessions_with_ar(str(prod_log))
    log.info("  %d sessions", len(sessions))

    log.info("Parsing GC entries...")
    gc_data = _parse_gc_log(str(prod_log))
    log.info("  %d GC entries", len(gc_data))

    log.info("Parsing monitor logs...")
    puma = _parse_puma_log(str(mon_dir / "puma.log"))
    pg = _parse_pg_summary(str(mon_dir / "pg-summary.log"))
    tomcat = _parse_tomcat_log(str(mon_dir / "tomcat-threads.log"))
    net = _parse_net_log(str(mon_dir / "net-conns.log"))
    log.info("  Puma: %d, PG: %d, Tomcat: %d, Net: %d samples",
             len(puma), len(pg), len(tomcat), len(net))

    # Analyze each level
    analyses = []
    for w in windows:
        log.info("Analyzing level %d...", w.level)
        a = _analyze_level(w, sessions, puma, pg, tomcat, net, gc_data,
                           args.bucket_size)
        analyses.append(a)

    # Render
    report = render_document(args.build, analyses)
    print(report)


if __name__ == "__main__":
    main()
