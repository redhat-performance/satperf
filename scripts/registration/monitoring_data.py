"""
monitoring_data.py - Parse per-batch JSON monitoring data from workdir-exporter.

Each registration test run produces per-concurrency-level JSON files at:
  {run_url}/50-concurrent-exec-{N}-Execute registration.log.json

These contain aggregated collectd metrics (CPU, memory, DB, process stats)
captured during the batch window.  This module loads those files into typed
dataclasses for use by compare_runs.py and future analysis scripts.
"""

import json
import logging
import re
import sys
import urllib.request
from dataclasses import dataclass, fields
from pathlib import Path
from typing import Dict, List, Optional

# Sibling module — shares HTTP helpers
sys.path.insert(0, str(Path(__file__).parent))
from common import _urlopen, configure_ssl

log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Dataclasses
# ---------------------------------------------------------------------------

_STAT_FIELDS = [
    "min", "max", "mean", "median",
    "p25", "p75", "p90", "p95", "p99",
    "stdev", "samples",
]

# JSON key → dataclass field name
_STAT_KEY_MAP = {
    "percentile25": "p25",
    "percentile75": "p75",
    "percentile90": "p90",
    "percentile95": "p95",
    "percentile99": "p99",
}


@dataclass
class Stats:
    """Statistical summary of a metric during one batch window."""
    min: float = 0.0
    max: float = 0.0
    mean: float = 0.0
    median: float = 0.0
    p25: float = 0.0
    p75: float = 0.0
    p90: float = 0.0
    p95: float = 0.0
    p99: float = 0.0
    stdev: float = 0.0
    samples: int = 0


@dataclass
class MonitoringMetrics:
    """All monitored metrics for one concurrency batch."""

    level: int = 0

    # Registration results
    passed: int = 0
    total: int = 0
    avg_duration_s: float = 0.0

    # System
    cpu_load: Optional[Stats] = None
    memory_used: Optional[Stats] = None
    swap_used: Optional[Stats] = None

    # Puma (Foreman app server)
    puma_worker_cpu: Optional[Stats] = None
    puma_worker_rss: Optional[Stats] = None
    puma_worker_threads: Optional[Stats] = None
    puma_worker_procs: Optional[Stats] = None

    # Tomcat (Candlepin)
    tomcat_cpu: Optional[Stats] = None
    tomcat_rss: Optional[Stats] = None

    # PostgreSQL
    postgres_cpu: Optional[Stats] = None
    postgres_rss: Optional[Stats] = None

    # httpd (Apache)
    httpd_cpu: Optional[Stats] = None
    httpd_rss: Optional[Stats] = None

    # Sidekiq
    sidekiq_cpu: Optional[Stats] = None

    # Foreman DB
    foreman_db_size: Optional[Stats] = None
    foreman_inserts: Optional[Stats] = None
    foreman_updates: Optional[Stats] = None
    foreman_deletes: Optional[Stats] = None

    # Candlepin DB
    candlepin_db_size: Optional[Stats] = None
    candlepin_inserts: Optional[Stats] = None
    candlepin_updates: Optional[Stats] = None
    candlepin_deletes: Optional[Stats] = None

    @property
    def pass_rate(self) -> float:
        return self.passed / self.total * 100 if self.total else 0.0


# ---------------------------------------------------------------------------
# JSON parsing
# ---------------------------------------------------------------------------

def _parse_stats(data: dict) -> Stats:
    """Parse a JSON stats block into a Stats dataclass."""
    kwargs = {}
    for json_key, value in data.items():
        attr = _STAT_KEY_MAP.get(json_key, json_key)
        if attr in {f.name for f in fields(Stats)}:
            kwargs[attr] = int(value) if attr == "samples" else float(value)
    return Stats(**kwargs)


def _extract(data: dict, *path: str) -> Optional[Stats]:
    """Navigate nested JSON by path segments, return Stats or None."""
    node = data
    for segment in path:
        if not isinstance(node, dict) or segment not in node:
            return None
        node = node[segment]
    if isinstance(node, dict) and "mean" in node:
        return _parse_stats(node)
    return None


# Metric path registry: (dataclass_field, *json_path_under_measurements.satellite)
_METRIC_MAP: List[tuple] = [
    # System
    ("cpu_load", "load", "load", "shortterm"),
    ("memory_used", "memory", "memory-used"),
    ("swap_used", "swap", "swap-used"),
    # Puma
    ("puma_worker_cpu", "processes-Puma-Worker", "ps_cputime", "user"),
    ("puma_worker_rss", "processes-Puma-Worker", "ps_rss"),
    ("puma_worker_threads", "processes-Puma-Worker", "ps_count", "threads"),
    ("puma_worker_procs", "processes-Puma-Worker", "ps_count", "processes"),
    # Tomcat
    ("tomcat_cpu", "processes-Tomcat", "ps_cputime", "user"),
    ("tomcat_rss", "processes-Tomcat", "ps_rss"),
    # PostgreSQL
    ("postgres_cpu", "processes-Postgres", "ps_cputime", "user"),
    ("postgres_rss", "processes-Postgres", "ps_rss"),
    # httpd
    ("httpd_cpu", "processes-httpd", "ps_cputime", "user"),
    ("httpd_rss", "processes-httpd", "ps_rss"),
    # Sidekiq
    ("sidekiq_cpu", "processes-sidekiq", "ps_cputime", "user"),
    # Foreman DB
    ("foreman_db_size", "postgresql-foreman", "pg_db_size"),
    ("foreman_inserts", "postgresql-foreman", "pg_n_tup_c-ins"),
    ("foreman_updates", "postgresql-foreman", "pg_n_tup_c-upd"),
    ("foreman_deletes", "postgresql-foreman", "pg_n_tup_c-del"),
    # Candlepin DB
    ("candlepin_db_size", "postgresql-candlepin", "pg_db_size"),
    ("candlepin_inserts", "postgresql-candlepin", "pg_n_tup_c-ins"),
    ("candlepin_updates", "postgresql-candlepin", "pg_n_tup_c-upd"),
    ("candlepin_deletes", "postgresql-candlepin", "pg_n_tup_c-del"),
]


def _parse_monitoring_json(data: dict, level: int = 0,
                           node: str = "satellite") -> MonitoringMetrics:
    """Parse a full monitoring JSON dict into MonitoringMetrics."""
    measurements = data.get("measurements", {}).get(node, {})
    items = data.get("results", {}).get("items", {})

    m = MonitoringMetrics(
        level=level,
        passed=int(items.get("passed", 0)),
        avg_duration_s=float(items.get("avg_duration", 0.0)),
    )
    # total is not in the JSON directly; infer from level (concurrent_total)
    # or leave as 0 if unavailable
    m.total = level if level > 0 else m.passed

    for entry in _METRIC_MAP:
        attr_name, *json_path = entry
        stats = _extract(measurements, *json_path)
        if stats is not None:
            setattr(m, attr_name, stats)

    return m


# ---------------------------------------------------------------------------
# Data loading
# ---------------------------------------------------------------------------

def _fetch_json(url: str) -> dict:
    """Fetch and parse a JSON URL."""
    resp = _urlopen(url)
    return json.loads(resp.read().decode("utf-8"))


def _discover_levels(run_url: str) -> List[int]:
    """List available concurrency levels by scraping the run directory."""
    run_url = run_url.rstrip("/")
    html = _urlopen(run_url + "/").read().decode("utf-8")
    pattern = re.compile(
        r'href="50-concurrent-exec-(\d+)-Execute%20registration\.log\.json"'
    )
    levels = sorted(int(m.group(1)) for m in pattern.finditer(html))
    return levels


def load_batch_monitoring(run_url: str, level: int,
                          node: str = "satellite") -> MonitoringMetrics:
    """Load monitoring data for one concurrency level."""
    run_url = run_url.rstrip("/")
    url = (f"{run_url}/50-concurrent-exec-{level}"
           f"-Execute%20registration.log.json")
    data = _fetch_json(url)
    return _parse_monitoring_json(data, level=level, node=node)


def load_all_monitoring(run_url: str,
                        node: str = "satellite") -> Dict[int, MonitoringMetrics]:
    """Load monitoring data for all concurrency levels in a run."""
    levels = _discover_levels(run_url)
    log.info("Discovered %d concurrency levels: %s", len(levels), levels)
    result = {}
    for level in levels:
        result[level] = load_batch_monitoring(run_url, level, node=node)
    return result


def load_overall_monitoring(run_url: str,
                            node: str = "satellite") -> Optional[MonitoringMetrics]:
    """Load the overall aggregation file, if it exists."""
    run_url = run_url.rstrip("/")
    url = (f"{run_url}/50-concurrent-exec-registration-overall"
           f"-Execute%20registration.log.json")
    try:
        data = _fetch_json(url)
        return _parse_monitoring_json(data, level=0, node=node)
    except Exception:
        log.debug("No overall monitoring file found")
        return None


# ---------------------------------------------------------------------------
# Build number → run URL resolution
# ---------------------------------------------------------------------------

def _list_run_dirs(workdir_base: str) -> List[str]:
    """List all run-* directories from the workdir-exporter."""
    workdir_base = workdir_base.rstrip("/")
    html = _urlopen(workdir_base + "/").read().decode("utf-8")
    # hrefs may use ./ prefix: href="./run-2026-04-24T06:17:32+00:00/"
    pattern = re.compile(r'href="\.?/?(run-[^"]+)/"')
    return [m.group(1) for m in pattern.finditer(html)]


def _run_dir_url(workdir_base: str, run_dir: str) -> str:
    """Build a URL for a run directory, quoting the + in timestamps."""
    return f"{workdir_base.rstrip('/')}/{urllib.request.quote(run_dir, safe=':-')}"


def resolve_build_to_run_url(workdir_base: str, build_number: int) -> str:
    """Resolve a Jenkins build number to a workdir-exporter run URL.

    Scans run directories and checks the first available batch JSON
    for results.jenkins.build_url containing the build number.
    """
    workdir_base = workdir_base.rstrip("/")
    target = f"/{build_number}/"

    for run_dir in _list_run_dirs(workdir_base):
        run_url = _run_dir_url(workdir_base, run_dir)
        try:
            levels = _discover_levels(run_url)
        except Exception:
            continue
        if not levels:
            continue
        try:
            url = (f"{run_url}/50-concurrent-exec-{levels[0]}"
                   f"-Execute%20registration.log.json")
            data = _fetch_json(url)
            build_url = (data.get("results", {})
                         .get("jenkins", {})
                         .get("build_url", ""))
            if target in build_url:
                log.info("Build %d → %s", build_number, run_url)
                return run_url
        except Exception:
            continue

    raise ValueError(f"Could not find run for build #{build_number}")


def discover_applied_prs(run_url: str) -> List[str]:
    """Read apply-prs-satellite.log to discover which PRs were applied."""
    run_url = run_url.rstrip("/")
    prs = []
    try:
        text = _urlopen(f"{run_url}/apply-prs-satellite.log").read().decode()
        # Look for PR numbers in the Ansible output
        for m in re.finditer(r'(\w+/\w+)#(\d+)', text):
            prs.append(f"{m.group(1)}#{m.group(2)}")
        if not prs:
            # Try parsing the YAML-style apply_prs parameter
            for m in re.finditer(r"org:\s*(\w+),\s*repo:\s*(\w+).*?prs:\s*\[([^\]]+)\]",
                                 text, re.DOTALL):
                org, repo = m.group(1), m.group(2)
                for pr_num in re.findall(r'\d+', m.group(3)):
                    prs.append(f"{org}/{repo}#{pr_num}")
    except Exception:
        log.debug("No apply-prs-satellite.log found for %s", run_url)
    return prs


# ---------------------------------------------------------------------------
# Stats averaging (for baseline runs)
# ---------------------------------------------------------------------------

def average_stats(stats_list: List[Stats]) -> Stats:
    """Average Stats across multiple runs."""
    n = len(stats_list)
    if n == 0:
        return Stats()
    if n == 1:
        return stats_list[0]
    result = Stats()
    for attr in _STAT_FIELDS:
        values = [getattr(s, attr) for s in stats_list]
        if attr == "samples":
            setattr(result, attr, int(sum(values) / n))
        else:
            setattr(result, attr, sum(values) / n)
    return result


def average_monitoring(runs: List[Dict[int, MonitoringMetrics]]
                       ) -> Dict[int, MonitoringMetrics]:
    """Average MonitoringMetrics across N runs, per concurrency level."""
    all_levels = sorted({lv for run in runs for lv in run})
    result = {}

    for level in all_levels:
        level_data = [run[level] for run in runs if level in run]
        n = len(level_data)
        if n == 0:
            continue

        avg = MonitoringMetrics(
            level=level,
            passed=int(sum(m.passed for m in level_data) / n),
            total=level,
            avg_duration_s=sum(m.avg_duration_s for m in level_data) / n,
        )

        # Average each Stats field
        for f in fields(MonitoringMetrics):
            if f.type != Optional[Stats]:
                continue
            stats_list = [getattr(m, f.name) for m in level_data
                          if getattr(m, f.name) is not None]
            if stats_list:
                setattr(avg, f.name, average_stats(stats_list))

        result[level] = avg

    return result


# ---------------------------------------------------------------------------
# CLI for standalone testing
# ---------------------------------------------------------------------------

def main() -> None:
    import argparse

    parser = argparse.ArgumentParser(
        description="Load and display monitoring data for a test run.")
    parser.add_argument("--workdir-base", required=True,
                        help="Workdir-exporter base URL (e.g. .../workspace/Sat_Red)")
    parser.add_argument("--build", type=int, required=True,
                        help="Jenkins build number")
    parser.add_argument("--no-verify-ssl", action="store_true")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()

    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(levelname)s: %(message)s")

    configure_ssl(args.no_verify_ssl)

    run_url = resolve_build_to_run_url(args.workdir_base, args.build)
    print(f"Build #{args.build} → {run_url}\n")

    prs = discover_applied_prs(run_url)
    if prs:
        print(f"Applied PRs: {', '.join(prs)}\n")

    monitoring = load_all_monitoring(run_url)

    # Summary table
    hdr = f"{'Level':>6} {'Passed':>7} {'Rate':>6} {'Avg(s)':>7} {'CPU Load':>9} {'Mem(GB)':>8} {'Puma CPU':>9} {'FrmIns':>9} {'CpIns':>9}"
    print(hdr)
    print("-" * len(hdr))

    for level in sorted(monitoring):
        m = monitoring[level]
        cpu = f"{m.cpu_load.mean:.1f}" if m.cpu_load else "-"
        mem = f"{m.memory_used.mean / 1e9:.1f}" if m.memory_used else "-"
        pcpu = f"{m.puma_worker_cpu.mean:.1f}" if m.puma_worker_cpu else "-"
        fins = f"{m.foreman_inserts.mean:.0f}" if m.foreman_inserts else "-"
        cins = f"{m.candlepin_inserts.mean:.0f}" if m.candlepin_inserts else "-"
        rate = f"{m.pass_rate:.0f}%"
        print(f"{level:>6} {m.passed:>7} {rate:>6} {m.avg_duration_s:>7.1f}"
              f" {cpu:>9} {mem:>8} {pcpu:>9} {fins:>9} {cins:>9}")


if __name__ == "__main__":
    main()
