"""
compare_runs.py — Cross-run registration performance comparison.

Compares baseline runs (averaged) against one or more batches with
different PR combinations, using JSON monitoring data from the
workdir-exporter.  Produces a Markdown report covering throughput,
resource consumption, database impact, and bottleneck analysis.

Usage:
  python3 compare_runs.py \\
    --workdir-base https://workdir-exporter-.../workspace/Sat_Red \\
    --baseline "1523 1524 1525" \\
    --batch "1528" \\
    --skip-sosreport --no-verify-ssl
"""

import argparse
import datetime
import logging
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional

sys.path.insert(0, str(Path(__file__).parent))
from common import configure_ssl
from monitoring_data import (
    MonitoringMetrics,
    average_monitoring,
    discover_applied_prs,
    load_all_monitoring,
    resolve_build_to_run_url,
)

log = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Dataclasses
# ---------------------------------------------------------------------------

@dataclass
class RunInfo:
    """One Jenkins build / test run."""
    build_number: int
    run_url: str
    prs: List[str] = field(default_factory=list)
    monitoring: Dict[int, MonitoringMetrics] = field(default_factory=dict)


@dataclass
class Batch:
    """A batch groups one or more runs that share the same PR set."""
    runs: List[RunInfo] = field(default_factory=list)
    avg: Dict[int, MonitoringMetrics] = field(default_factory=dict)

    @property
    def prs(self) -> List[str]:
        for r in self.runs:
            if r.prs:
                return r.prs
        return []

    @property
    def build_numbers(self) -> List[int]:
        return [r.build_number for r in self.runs]

    @property
    def label(self) -> str:
        nums = ", ".join(str(b) for b in self.build_numbers)
        return nums


@dataclass
class ComparisonData:
    """Everything needed to render the comparison report."""
    generated_at: str
    workdir_base: str
    levels: List[int]
    # Baseline: averaged across N runs
    baseline: Batch = field(default_factory=Batch)
    # Batches (each may contain multiple runs, averaged)
    batches: List[Batch] = field(default_factory=list)


# ---------------------------------------------------------------------------
# Data collection
# ---------------------------------------------------------------------------

def _pct_delta(baseline: float, batch: float) -> str:
    """Format a percentage delta, handling zero baseline."""
    if baseline == 0:
        return "-"
    delta = (batch - baseline) / baseline * 100
    sign = "+" if delta > 0 else ""
    return f"{sign}{delta:.0f}%"


def _pp_delta(baseline: float, batch: float) -> str:
    """Format a percentage-point delta."""
    delta = batch - baseline
    sign = "+" if delta > 0 else ""
    return f"{sign}{delta:.0f} pp"


def _load_batch(workdir_base: str, build_numbers: List[int]) -> Batch:
    """Load and average monitoring data for a batch of runs."""
    batch = Batch()
    monitoring_list = []
    for build in build_numbers:
        run_url = resolve_build_to_run_url(workdir_base, build)
        prs = discover_applied_prs(run_url)
        monitoring = load_all_monitoring(run_url)
        batch.runs.append(RunInfo(build_number=build, run_url=run_url,
                                  prs=prs, monitoring=monitoring))
        monitoring_list.append(monitoring)
    batch.avg = average_monitoring(monitoring_list)
    return batch


def collect_data(workdir_base: str,
                 baseline_builds: List[int],
                 batch_build_groups: List[List[int]]) -> ComparisonData:
    """Load monitoring data for all runs and compute comparisons."""
    data = ComparisonData(
        generated_at=datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC"),
        workdir_base=workdir_base,
        levels=[],
    )

    log.info("Loading %d baseline runs...", len(baseline_builds))
    data.baseline = _load_batch(workdir_base, baseline_builds)
    data.levels = sorted(data.baseline.avg.keys())

    for i, builds in enumerate(batch_build_groups):
        log.info("Loading batch %d (%d runs)...", i + 1, len(builds))
        batch = _load_batch(workdir_base, builds)
        data.batches.append(batch)
        for lv in batch.avg:
            if lv not in data.levels:
                data.levels.append(lv)

    data.levels = sorted(set(data.levels))
    return data


# ---------------------------------------------------------------------------
# Markdown rendering helpers
# ---------------------------------------------------------------------------

def _stat_val(m: Optional[MonitoringMetrics], attr: str,
              stat: str = "mean", scale: float = 1.0,
              fmt: str = ".1f") -> str:
    """Extract a formatted stat value from a MonitoringMetrics field."""
    if m is None:
        return "-"
    stats_obj = getattr(m, attr, None)
    if stats_obj is None:
        return "-"
    val = getattr(stats_obj, stat, 0.0) * scale
    return f"{val:{fmt}}"


def _delta_str(bl_val: str, batch_val: str) -> str:
    """Compute delta string from two formatted values."""
    try:
        bl = float(bl_val.replace(",", ""))
        bt = float(batch_val.replace(",", ""))
    except (ValueError, AttributeError):
        return "-"
    return _pct_delta(bl, bt)


# ---------------------------------------------------------------------------
# Report sections
# ---------------------------------------------------------------------------

def render_header(data: ComparisonData) -> str:
    lines = [
        "# Registration Performance Comparison",
        "",
        f"**Generated:** {data.generated_at}  ",
        f"**Baseline:** builds {data.baseline.label}"
        f" ({len(data.baseline.runs)} runs, averaged)  ",
    ]
    for i, batch in enumerate(data.batches):
        pr_str = ", ".join(batch.prs) if batch.prs else "none detected"
        n_runs = f" ({len(batch.runs)} runs, averaged)" if len(batch.runs) > 1 else ""
        lines.append(f"**Batch {i+1}:** builds {batch.label}{n_runs}"
                     f" — PRs: {pr_str}  ")
    lines.append("")
    return "\n".join(lines)


def render_throughput(data: ComparisonData) -> str:
    lines = ["## Throughput by Concurrency Level", ""]

    # Build header
    hdr = "| Concurrent | BL passed | BL rate | BL avg(s) |"
    sep = "|---:|---:|---:|---:|"
    for i, batch in enumerate(data.batches):
        label = f"B{i+1}"
        hdr += f" {label} passed | {label} rate | {label} avg(s) | {label} Δavg |"
        sep += "---:|---:|---:|---:|"
    lines.extend([hdr, sep])

    for lv in data.levels:
        bl = data.baseline.avg.get(lv)
        bl_passed = bl.passed if bl else 0
        bl_rate = f"{bl.pass_rate:.0f}%" if bl else "-"
        bl_avg = f"{bl.avg_duration_s:.1f}" if bl else "-"
        row = f"| {lv} | {bl_passed} | {bl_rate} | {bl_avg} |"

        for batch in data.batches:
            bm = batch.avg.get(lv)
            if bm:
                b_passed = bm.passed
                b_rate = f"{bm.pass_rate:.0f}%"
                b_avg = f"{bm.avg_duration_s:.1f}"
                d_avg = _pct_delta(bl.avg_duration_s, bm.avg_duration_s) if bl else "-"
                row += f" {b_passed} | {b_rate} | {b_avg} | **{d_avg}** |"
            else:
                row += " - | - | - | - |"
        lines.append(row)

    lines.append("")
    return "\n".join(lines)


def render_resource_comparison(data: ComparisonData) -> str:
    lines = ["## Resource Consumption", ""]

    metrics = [
        ("CPU Load (mean)", "cpu_load", "mean", 1.0, ".1f"),
        ("Memory Used (GB, mean)", "memory_used", "mean", 1e-9, ".1f"),
        ("Puma Worker CPU (mean)", "puma_worker_cpu", "mean", 1.0, ".1f"),
        ("Puma Worker RSS (GB, mean)", "puma_worker_rss", "mean", 1e-9, ".1f"),
        ("Puma Threads (mean)", "puma_worker_threads", "mean", 1.0, ".0f"),
        ("Tomcat CPU (mean)", "tomcat_cpu", "mean", 1.0, ".1f"),
        ("Tomcat RSS (GB, mean)", "tomcat_rss", "mean", 1e-9, ".1f"),
        ("PostgreSQL CPU (mean)", "postgres_cpu", "mean", 1.0, ".1f"),
        ("httpd CPU (mean)", "httpd_cpu", "mean", 1.0, ".1f"),
    ]

    for metric_label, attr, stat, scale, fmt in metrics:
        lines.append(f"### {metric_label}")
        lines.append("")

        hdr = "| Concurrent | Baseline |"
        sep = "|---:|---:|"
        for i in range(len(data.batches)):
            hdr += f" B{i+1} | Δ |"
            sep += "---:|---:|"
        lines.extend([hdr, sep])

        for lv in data.levels:
            bl = data.baseline.avg.get(lv)
            bl_val = _stat_val(bl, attr, stat, scale, fmt)
            row = f"| {lv} | {bl_val} |"

            for batch in data.batches:
                bm = batch.avg.get(lv)
                b_val = _stat_val(bm, attr, stat, scale, fmt)
                delta = _delta_str(bl_val, b_val)
                row += f" {b_val} | **{delta}** |"
            lines.append(row)

        lines.append("")

    return "\n".join(lines)


def render_db_comparison(data: ComparisonData) -> str:
    lines = ["## Database Impact", ""]

    db_metrics = [
        ("Foreman DB Inserts (mean/interval)", "foreman_inserts"),
        ("Foreman DB Updates (mean/interval)", "foreman_updates"),
        ("Foreman DB Deletes (mean/interval)", "foreman_deletes"),
        ("Candlepin DB Inserts (mean/interval)", "candlepin_inserts"),
        ("Candlepin DB Updates (mean/interval)", "candlepin_updates"),
        ("Foreman DB Size (MB, mean)", "foreman_db_size"),
        ("Candlepin DB Size (MB, mean)", "candlepin_db_size"),
    ]

    for metric_label, attr in db_metrics:
        scale = 1e-6 if "Size" in metric_label else 1.0
        fmt = ".1f" if "Size" in metric_label else ".0f"

        lines.append(f"### {metric_label}")
        lines.append("")

        hdr = "| Concurrent | Baseline |"
        sep = "|---:|---:|"
        for i in range(len(data.batches)):
            hdr += f" B{i+1} | Δ |"
            sep += "---:|---:|"
        lines.extend([hdr, sep])

        for lv in data.levels:
            bl = data.baseline.avg.get(lv)
            bl_val = _stat_val(bl, attr, "mean", scale, fmt)
            row = f"| {lv} | {bl_val} |"

            for batch in data.batches:
                bm = batch.avg.get(lv)
                b_val = _stat_val(bm, attr, "mean", scale, fmt)
                delta = _delta_str(bl_val, b_val)
                row += f" {b_val} | **{delta}** |"
            lines.append(row)

        lines.append("")

    return "\n".join(lines)


def render_executive_summary(data: ComparisonData) -> str:
    """Key deltas across all concurrency levels (overall averages)."""
    lines = ["## Executive Summary", ""]

    hdr = "| Metric | Baseline |"
    sep = "|---|---:|"
    for i, batch in enumerate(data.batches):
        hdr += f" B{i+1} (#{batch.label}) | Δ |"
        sep += "---:|---:|"
    lines.extend([hdr, sep])

    # Aggregate across levels
    bl_levels = [data.baseline.avg[lv] for lv in data.levels
                 if lv in data.baseline.avg]

    def _agg(metrics_list, attr, stat="mean"):
        vals = []
        for m in metrics_list:
            s = getattr(m, attr, None)
            if s is not None:
                vals.append(getattr(s, stat, 0.0))
        return sum(vals) / len(vals) if vals else 0.0

    # Overall pass rate
    bl_passed = sum(m.passed for m in bl_levels)
    bl_total = sum(m.total for m in bl_levels)
    bl_rate = bl_passed / bl_total * 100 if bl_total else 0

    row = f"| Total registered / attempted | {bl_passed} / {bl_total} ({bl_rate:.0f}%) |"
    for batch in data.batches:
        b_levels = [batch.avg[lv] for lv in data.levels
                    if lv in batch.avg]
        b_passed = sum(m.passed for m in b_levels)
        b_total = sum(m.total for m in b_levels)
        b_rate = b_passed / b_total * 100 if b_total else 0
        d_rate = _pp_delta(bl_rate, b_rate)
        row += f" {b_passed} / {b_total} ({b_rate:.0f}%) | **{d_rate}** |"
    lines.append(row)

    # Avg registration time (weighted by passed count)
    bl_weighted = sum(m.avg_duration_s * m.passed for m in bl_levels)
    bl_avg = bl_weighted / bl_passed if bl_passed else 0
    row = f"| Avg registration time (s) | {bl_avg:.1f} |"
    for batch in data.batches:
        b_levels = [batch.avg[lv] for lv in data.levels
                    if lv in batch.avg]
        b_passed_t = sum(m.passed for m in b_levels)
        b_weighted = sum(m.avg_duration_s * m.passed for m in b_levels)
        b_avg = b_weighted / b_passed_t if b_passed_t else 0
        row += f" {b_avg:.1f} | **{_pct_delta(bl_avg, b_avg)}** |"
    lines.append(row)

    # Summary resource metrics
    summary_metrics = [
        ("CPU load (mean across levels)", "cpu_load", 1.0, ".1f"),
        ("Memory used (GB, mean)", "memory_used", 1e-9, ".1f"),
        ("Foreman DB inserts (mean)", "foreman_inserts", 1.0, ".0f"),
        ("Candlepin DB inserts (mean)", "candlepin_inserts", 1.0, ".0f"),
        ("Puma worker CPU (mean)", "puma_worker_cpu", 1.0, ".1f"),
    ]

    for label, attr, scale, fmt in summary_metrics:
        bl_val = _agg(bl_levels, attr) * scale
        row = f"| {label} | {bl_val:{fmt}} |"
        for batch in data.batches:
            b_levels = [batch.avg[lv] for lv in data.levels
                        if lv in batch.avg]
            b_val = _agg(b_levels, attr) * scale
            row += f" {b_val:{fmt}} | **{_pct_delta(bl_val, b_val)}** |"
        lines.append(row)

    lines.append("")
    return "\n".join(lines)


def render_bottleneck_analysis(data: ComparisonData) -> str:
    lines = ["## Bottleneck Analysis", ""]

    # Find first level where pass rate drops below 100%
    for label, source in [("Baseline", data.baseline.avg)] + \
            [(f"B{i+1}", b.avg) for i, b in enumerate(data.batches)]:
        cliff_level = None
        for lv in data.levels:
            m = source.get(lv)
            if m and m.pass_rate < 95:
                cliff_level = lv
                break
        if cliff_level:
            m = source[cliff_level]
            lines.append(f"- **{label}**: pass rate drops below 100% at"
                         f" **{cliff_level}** concurrent"
                         f" ({m.pass_rate:.0f}%, {m.passed}/{m.total})")
        else:
            lines.append(f"- **{label}**: 100% pass rate at all tested levels")

    lines.extend(["", "### Observations", ""])

    # Compare foreman inserts at low concurrency (bulk-insert impact)
    low_lv = data.levels[0] if data.levels else None
    if low_lv:
        bl = data.baseline.avg.get(low_lv)
        for i, batch in enumerate(data.batches):
            bm = batch.avg.get(low_lv)
            if bl and bm and bl.foreman_inserts and bm.foreman_inserts:
                delta = _pct_delta(bl.foreman_inserts.mean,
                                   bm.foreman_inserts.mean)
                lines.append(
                    f"- At {low_lv} concurrent, B{i+1} foreman DB inserts:"
                    f" {bl.foreman_inserts.mean:.0f} → {bm.foreman_inserts.mean:.0f}"
                    f" ({delta}) — bulk-insert PR impact")

    # Compare Puma CPU across levels
    if data.levels:
        mid_lv = data.levels[len(data.levels) // 2]
        bl = data.baseline.avg.get(mid_lv)
        for i, batch in enumerate(data.batches):
            bm = batch.avg.get(mid_lv)
            if bl and bm and bl.puma_worker_cpu and bm.puma_worker_cpu:
                delta = _pct_delta(bl.puma_worker_cpu.mean,
                                   bm.puma_worker_cpu.mean)
                lines.append(
                    f"- At {mid_lv} concurrent, B{i+1} Puma CPU time:"
                    f" {bl.puma_worker_cpu.mean:.1f} → {bm.puma_worker_cpu.mean:.1f}"
                    f" ({delta}) — less time per request = faster throughput")

    lines.append("")
    return "\n".join(lines)


def render_document(data: ComparisonData) -> str:
    """Assemble the complete report."""
    sections = [
        render_header(data),
        render_executive_summary(data),
        render_throughput(data),
        render_resource_comparison(data),
        render_db_comparison(data),
        render_bottleneck_analysis(data),
    ]
    return "\n".join(sections)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Compare registration performance across test runs.")
    parser.add_argument("--workdir-base", required=True,
                        help="Workdir-exporter base URL")
    parser.add_argument("--baseline", required=True,
                        help="Space-separated baseline build numbers (quoted)")
    parser.add_argument("--batch", action="append", default=[],
                        help="Build numbers for a batch (quoted, space-separated)."
                             " Repeatable for multiple batches.")
    parser.add_argument("--no-verify-ssl", action="store_true")
    parser.add_argument("--skip-sosreport", action="store_true",
                        help="Skip sosreport analysis (JSON monitoring only)")
    parser.add_argument("--cache-dir",
                        help="Directory for sosreport cache (persistent)")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(levelname)s: %(message)s",
        stream=sys.stderr,
    )

    configure_ssl(args.no_verify_ssl)

    baseline_builds = [int(b) for b in args.baseline.split()]
    # Each --batch value is a space-separated string of build numbers
    batch_build_groups = [[int(b) for b in group.split()]
                          for group in args.batch]

    if not batch_build_groups:
        parser.error("At least one --batch is required")

    if args.cache_dir:
        log.info("Cache directory: %s", args.cache_dir)

    data = collect_data(args.workdir_base, baseline_builds, batch_build_groups)
    report = render_document(data)
    print(report)


if __name__ == "__main__":
    main()
