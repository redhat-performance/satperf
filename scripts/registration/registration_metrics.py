#!/usr/bin/env python3
"""
registration_metrics.py - Foreman/Satellite host registration performance analysis

Parses production.log from Satellite (and optionally Capsule/LB) hosts to
extract per-registration timing metrics correlated by consumer UUID.

Each metric is tied directly to a specific in-flight PR:
  POST /rhsm/consumers duration  -> foreman#10942 + katello#11701
  GET  /compliance call count    -> katello#11692 (compliance caching)
  GET  /rhsm/status call count   -> katello#11696 (status caching)
  GET  /rhsm/consumers redundant -> katello#11694 (eliminate redundant GETs)
  GET  /register P99             -> smart-proxy#935 (script caching)

Usage:
  # Ansible inventory — SSH to all satellite6 hosts (recommended)
  ./registration_metrics.py --inventory conf/hosts.ini

  # Single sosreport archive or extracted directory
  ./registration_metrics.py --sosreport satellite.tar.xz
  ./registration_metrics.py --sosreport /path/to/extracted/sosreport/

  # Directory of sosreport archives (local path or HTTP URL)
  ./registration_metrics.py --sosreport-dir /path/to/run-2026-04-01/sosreport/
  ./registration_metrics.py --sosreport-dir https://workdir-exporter.apps.example.com/.../sosreport/

  # Direct log file (plain or .gz)
  ./registration_metrics.py --log /var/log/foreman/production.log

  # Compare two runs (each BEFORE/AFTER accepts the same formats above)
  ./registration_metrics.py --compare /path/to/before/ /path/to/after/
  ./registration_metrics.py --compare https://.../run-before/ https://.../run-after/

  # JSON output
  ./registration_metrics.py --log production.log --json
"""

import argparse
import bisect
import collections
import configparser
import datetime
import gzip
import json
import logging
import lzma
import os
import re
import shlex
import statistics
import subprocess
import ssl
import sys
import tarfile
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, Iterator, List, Optional, Tuple

# Mutated by main() when --no-verify-ssl is passed; avoids a global statement.
_HTTP_OPTS: dict = {}


def _urlopen(url: str):
    """Wrapper around urllib.request.urlopen that respects --no-verify-ssl."""
    return urllib.request.urlopen(url, **_HTTP_OPTS)

# ---------------------------------------------------------------------------
# production.log patterns
# Format: 2024-01-15T15:41:19 [I|app|abc12345] Started POST "/path" for IP
#         2024-01-15T15:41:22 [I|app|abc12345] Completed 201 Created in 3256ms
# ---------------------------------------------------------------------------

_RE_LOG_LINE = re.compile(
    r'^(\S+) \[[^\|]+\|[^\|]+\|([a-zA-Z0-9]+)\] (.+)$'
)
_RE_STARTED = re.compile(
    r'^Started (GET|POST|PUT|DELETE|PATCH) "([^"?]+)'
)
_RE_SOURCE_IP = re.compile(r' for ([\da-fA-F:\.]+)(?:\s|$)')

# Audit log lines written during POST /rhsm/consumers — same req_id, exact UUID.
# Both ContentFacet and SubscriptionFacet carry the same UUID; we match either:
#   [I|aud|REQ_ID] Katello::Host::ContentFacet (N) create event on uuid UUID
#   [I|aud|REQ_ID] Katello::Host::SubscriptionFacet (N) create event on uuid UUID
_RE_FACET_UUID = re.compile(
    r'^Katello::Host::\w+Facet \(\d+\) create event on uuid '
    r'([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$'
)
_RE_COMPLETED = re.compile(
    r'^Completed (\d+) .* in (\d+)ms'
)
_RE_CONSUMER_UUID = re.compile(
    r'/consumers/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})'
)

# Cache HIT/MISS lines emitted by the :registration logger (katello#11692 / #11696).
# These appear in production.log when those PRs are applied and the logger is at debug level.
# Body format (group 3 of _RE_LOG_LINE):
#   compliance cache=HIT uuid=UUID   |  compliance cache=MISS uuid=UUID
#   rhsm_status cache=HIT            |  rhsm_status cache=MISS
_RE_CACHE_COMPLIANCE = re.compile(r'^compliance cache=(HIT|MISS)')
_RE_CACHE_STATUS = re.compile(r'^rhsm_status cache=(HIT|MISS)')

# Cache HIT/MISS lines emitted by foreman-proxy (smart-proxy#935).
# These appear in proxy.log at INFO level when that PR is applied.
# Body format (group 3 of _RE_PROXY_LINE):
#   registration_script cache=HIT age=42s key_prefix=...
#   registration_script cache=MISS key_prefix=...
_RE_CACHE_SCRIPT = re.compile(r'^registration_script cache=(HIT|MISS)')

# Paths that matter for registration analysis
_P_CONSUMER_CREATE = re.compile(r'^/rhsm/consumers$')
_P_COMPLIANCE = re.compile(r'^/rhsm/consumers/[^/]+/compliance$')
_P_STATUS = re.compile(r'^/rhsm/status$')
_P_CONSUMER_ID = re.compile(r'^/rhsm/consumers/[^/]+$')   # GET or PUT
_P_REGISTER = re.compile(r'^/register$')                   # GET or POST

# Log paths to look for inside sosreports (relative, without leading slash)
_SATELLITE_LOG_PATHS = [
    'var/log/foreman/production.log',
    'var/log/foreman/production.log.1',
    'var/log/foreman/production.log.1.gz',
]

_CAPSULE_LOG_PATHS = [
    'var/log/foreman-proxy/proxy.log',
    'var/log/foreman-proxy/proxy.log.1',
    'var/log/foreman-proxy/proxy.log.1.gz',
]

# ---------------------------------------------------------------------------
# foreman-proxy proxy.log patterns
# Format: 2026-04-04T17:59:38 e3c9c5ad [I] Started GET /register ...
#         2026-04-04T17:59:38 1d83b327 [I] Finished GET /register with 200 (351.05 ms)
# ---------------------------------------------------------------------------

_RE_PROXY_LINE = re.compile(
    r'^(\S+)\s+([a-f0-9]{8})\s+\[[^\]]+\]\s+(.+)$'
)
_RE_PROXY_STARTED = re.compile(
    r'^Started (GET|POST|PUT|DELETE|PATCH) (/[^\s?]*)'
)
_RE_PROXY_FINISHED = re.compile(
    r'^Finished \S+ \S+ with (\d+) \((\d+(?:\.\d+)?) ms\)'
)


# ---------------------------------------------------------------------------
# Data structures
# ---------------------------------------------------------------------------

@dataclass
class _Req:
    req_id: str
    method: str
    path: str
    ts: Optional[datetime.datetime]
    source_ip: str = ''
    status: int = 0
    duration_ms: int = 0
    consumer_uuid: str = ''   # populated from audit log for POST /rhsm/consumers


@dataclass
class CacheStats:
    """Cache HIT/MISS counts from production.log and proxy.log.

    Populated by parse_sat_cache_stats() (katello#11692 / #11696) and
    parse_proxy_cache_stats() (smart-proxy#935).  All counters are zero when
    the relevant PRs have not been applied or logging is not enabled at the
    required level.  Check has_data before rendering.
    """
    compliance_hits: int = 0
    compliance_misses: int = 0
    status_hits: int = 0
    status_misses: int = 0
    script_hits: int = 0
    script_misses: int = 0

    @property
    def has_data(self) -> bool:
        return (self.compliance_hits + self.compliance_misses
                + self.status_hits + self.status_misses
                + self.script_hits + self.script_misses) > 0

    def _rate(self, hits: int, misses: int) -> Optional[str]:
        total = hits + misses
        return f'{hits / total * 100:.1f}%' if total else None

    @property
    def compliance_rate(self) -> Optional[str]:
        return self._rate(self.compliance_hits, self.compliance_misses)

    @property
    def status_rate(self) -> Optional[str]:
        return self._rate(self.status_hits, self.status_misses)

    @property
    def script_rate(self) -> Optional[str]:
        return self._rate(self.script_hits, self.script_misses)


@dataclass
class RegistrationSession:
    """Server-side view of one host registration, keyed by consumer UUID."""
    consumer_uuid: str
    started_at: Optional[datetime.datetime]
    consumer_create_req_id: str = ''  # req_id of the POST /rhsm/consumers anchor
    consumer_create_ms: int = 0     # POST /rhsm/consumers   (key bottleneck)
    consumer_create_status: int = 0
    script_fetch_ms: int = 0        # GET  /register
    host_register_ms: int = 0       # POST /register
    fact_update_ms: int = 0         # PUT  /rhsm/consumers/:id (step 6)
    compliance_calls: int = 0       # count of GET /compliance
    status_calls: int = 0           # count of GET /rhsm/status
    redundant_consumer_gets: int = 0  # GET /rhsm/consumers/:id (0 after #11694)
    source_ip: str = ''
    routing: str = 'direct'         # 'direct', 'capsule:<host>', 'lb:<host>'
    rex_mode: str = 'ssh'           # 'ssh' or 'mqtt'


@dataclass
class Metrics:
    source_label: str
    window_start: Optional[datetime.datetime]
    window_end: Optional[datetime.datetime]
    session_count: int
    error_count: int = 0
    error_breakdown: Dict[str, int] = field(default_factory=dict)
    consumer_create_ms: List[int] = field(default_factory=list)
    script_fetch_ms: List[int] = field(default_factory=list)
    host_register_ms: List[int] = field(default_factory=list)
    fact_update_ms: List[int] = field(default_factory=list)
    compliance_calls: List[int] = field(default_factory=list)
    status_calls: List[int] = field(default_factory=list)
    redundant_consumer_gets: List[int] = field(default_factory=list)


# ---------------------------------------------------------------------------
# Error categorisation
# ---------------------------------------------------------------------------

def _error_type(status: int) -> str:
    """Classify an HTTP status code into a human-readable error category."""
    if status == 0:
        return 'timeout/no-response'
    if status == 401:
        return 'auth-failure'
    if status == 403:
        return 'auth-failure'
    if status == 429:
        return 'rate-limited'
    if status >= 500:
        return 'server-error'
    if status >= 400:
        return 'client-error'
    return 'ok'


# ---------------------------------------------------------------------------
# Statistics helpers
# ---------------------------------------------------------------------------

def _pct(values: List[int], p: float) -> int:
    if not values:
        return 0
    s = sorted(values)
    idx = max(0, int(p / 100.0 * len(s)) - 1)
    return s[min(idx, len(s) - 1)]


def _p50_p95_p99(values: List[int]) -> Tuple[int, int, int]:
    return _pct(values, 50), _pct(values, 95), _pct(values, 99)


def _avg(values: List[int]) -> float:
    return statistics.mean(values) if values else 0.0


# ---------------------------------------------------------------------------
# Timestamp parsing
# ---------------------------------------------------------------------------

_TS_FMTS = ('%Y-%m-%dT%H:%M:%S', '%Y-%m-%d %H:%M:%S')


def _parse_ts(s: str) -> Optional[datetime.datetime]:
    s = s[:19]
    for fmt in _TS_FMTS:
        try:
            return datetime.datetime.strptime(s, fmt)
        except ValueError:
            continue
    return None


# ---------------------------------------------------------------------------
# Log line sources
# ---------------------------------------------------------------------------

def _lines_from_file(path: str) -> Iterator[str]:
    if path.endswith('.gz'):
        with gzip.open(path, 'rt', errors='replace') as f:
            yield from f
    else:
        with open(path, 'r', errors='replace') as f:
            yield from f


def _lines_from_fileobj(fobj, name: str = '') -> Iterator[str]:
    """Yield text lines from a binary or text file-like object."""
    if name.endswith('.gz'):
        with gzip.open(fobj, 'rt', errors='replace') as f:
            yield from f
    else:
        for raw in fobj:
            yield raw.decode('utf-8', errors='replace') if isinstance(raw, bytes) else raw


def _lines_from_ssh(host: str, remote_path: str, user: str = 'root',
                    key_file: Optional[str] = None,
                    ssh_args: Optional[str] = None,
                    limit_mb: int = 200) -> Iterator[str]:
    cmd = ['ssh']
    if key_file:
        cmd += ['-i', key_file]
    if ssh_args:
        cmd += shlex.split(ssh_args)
    cmd += [f'{user}@{host}',
            f'tail -c {limit_mb * 1024 * 1024} {remote_path}']
    logging.debug('SSH cmd: %s', ' '.join(cmd))
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True)
        yield from proc.stdout
        proc.wait()
        if proc.returncode not in (0, 141):  # 141 = SIGPIPE (expected when piped)
            err = proc.stderr.read().strip()
            if err:
                logging.warning('SSH %s %s: %s', host, remote_path, err)
    except FileNotFoundError:
        logging.error('ssh binary not found in PATH')


def _lines_from_tarball_member(tf: tarfile.TarFile,
                               member: tarfile.TarInfo) -> Iterator[str]:
    fobj = tf.extractfile(member)
    if fobj is None:
        return
    yield from _lines_from_fileobj(fobj, member.name)


def _open_tarball(path_or_url: str) -> tarfile.TarFile:
    """Open a .tar.xz or .tar.gz from a local path or HTTP URL."""
    if path_or_url.startswith(('http://', 'https://')):
        logging.info('Fetching %s', path_or_url)
        response = _urlopen(path_or_url)
        if '.xz' in path_or_url:
            return tarfile.open(fileobj=lzma.open(response), mode='r|')
        return tarfile.open(fileobj=gzip.open(response), mode='r|')
    return tarfile.open(path_or_url, mode='r:*')


def _production_log_lines_from_tarball(path_or_url: str) -> Iterator[str]:
    """Yield production.log lines from a satellite sosreport tarball (local or HTTP)."""
    with _open_tarball(path_or_url) as tf:
        for member in tf:
            # Strip leading sosreport-hostname-date/ component
            parts = member.name.split('/', 1)
            rel = parts[1] if len(parts) > 1 else member.name
            if any(rel == p or rel == p + '.gz' for p in _SATELLITE_LOG_PATHS):
                logging.info('Extracting %s from %s', rel, path_or_url)
                yield from _lines_from_tarball_member(tf, member)


def proxy_log_lines_from_tarball(path_or_url: str) -> Iterator[str]:
    """Yield proxy.log lines from a capsule sosreport tarball (local or HTTP)."""
    with _open_tarball(path_or_url) as tf:
        for member in tf:
            parts = member.name.split('/', 1)
            rel = parts[1] if len(parts) > 1 else member.name
            if any(rel == p or rel == p + '.gz' for p in _CAPSULE_LOG_PATHS):
                logging.info('Extracting %s from %s', rel, path_or_url)
                yield from _lines_from_tarball_member(tf, member)


def _list_http_dir(url: str) -> List[str]:
    """Return .tar.xz and .tar.gz URLs found in an HTTP directory listing."""
    url = url.rstrip('/') + '/'
    try:
        with _urlopen(url) as resp:
            html = resp.read().decode('utf-8', errors='replace')
    except Exception as exc:
        logging.error('Cannot fetch directory listing %s: %s', url, exc)
        return []
    results = []
    for href, _ in re.findall(r'href="([^"]+\.tar\.(xz|gz))"', html):
        if href.startswith(('http://', 'https://')):
            results.append(href)
        elif href.startswith('/'):
            from urllib.parse import urlparse
            p = urlparse(url)
            results.append(f'{p.scheme}://{p.netloc}{href}')
        else:
            results.append(url + href)
    return results


def _production_log_lines_from_dir(path_or_url: str) -> Iterator[str]:
    """Yield lines from all sosreport archives in a local dir or HTTP URL."""
    if path_or_url.startswith(('http://', 'https://')):
        archives = _list_http_dir(path_or_url)
        logging.info('Found %d archives at %s', len(archives), path_or_url)
        for url in archives:
            yield from _production_log_lines_from_tarball(url)
    else:
        p = Path(path_or_url)
        archives = sorted(p.glob('*.tar.xz')) + sorted(p.glob('*.tar.gz'))
        for archive in archives:
            yield from _production_log_lines_from_tarball(str(archive))


def _lines_for_source(source: str, limit_mb: int = 200) -> Iterator[str]:
    """Route a source descriptor (path, URL, or log file) to the right reader."""
    if source.startswith(('http://', 'https://')):
        yield from _production_log_lines_from_dir(source)
    elif os.path.isdir(source):
        p = Path(source)
        archives = list(p.glob('*.tar.xz')) + list(p.glob('*.tar.gz'))
        if archives:
            yield from _production_log_lines_from_dir(source)
        else:
            # Extracted sosreport — find production.log inside
            for rel in _SATELLITE_LOG_PATHS:
                log_path = p / rel
                if log_path.exists():
                    logging.info('Reading %s', log_path)
                    yield from _lines_from_file(str(log_path))
    elif source.endswith(('.tar.xz', '.tar.gz')):
        yield from _production_log_lines_from_tarball(source)
    else:
        yield from _lines_from_file(source)


# ---------------------------------------------------------------------------
# Ansible inventory parser
# ---------------------------------------------------------------------------

@dataclass
class _InventoryHost:
    hostname: str
    role: str   # 'satellite' | 'capsule' | 'lb'
    user: str
    key_file: Optional[str]
    ssh_args: Optional[str]


_ROLE_MAP = {
    'satellite6': 'satellite',
    'capsules': 'capsule',
    'capsule_lbs': 'lb',
}


def _parse_inventory(path: str) -> List[_InventoryHost]:
    """Parse an Ansible INI inventory file into a list of typed hosts."""
    inv_dir = os.path.dirname(os.path.abspath(path))
    with open(path, 'r') as f:
        raw = f.read()

    cp = configparser.RawConfigParser(allow_no_value=True)
    # Prefix with a DEFAULT section so configparser accepts Ansible's bare keys
    cp.read_string('[__root__]\n' + raw)

    def _strip_quotes(v: Optional[str]) -> str:
        return (v or '').strip("'\"")

    # Global vars from [all:vars]
    g: Dict[str, str] = {}
    if cp.has_section('all:vars'):
        g = {k: _strip_quotes(v) for k, v in cp.items('all:vars')}

    user = g.get('ansible_user', 'root')
    key_raw = g.get('ansible_ssh_private_key_file')
    key_file: Optional[str] = None
    if key_raw:
        if os.path.isabs(key_raw):
            key_file = key_raw
        else:
            # Ansible resolves key paths relative to the working directory where
            # the playbook is run (typically the repo root), not relative to the
            # inventory file. Walk up from inv_dir until we find the file.
            d = inv_dir
            for _ in range(6):
                candidate = os.path.join(d, key_raw)
                if os.path.isfile(candidate):
                    key_file = candidate
                    break
                parent = os.path.dirname(d)
                if parent == d:
                    break
                d = parent
            if key_file is None:
                logging.warning('SSH key not found: %s (searched from %s)', key_raw, inv_dir)
    ssh_args = g.get('ansible_ssh_common_args') or None

    # Collect per-host variables (private_ip, rex_mode, …) by parsing the raw
    # file directly.  configparser splits on the first '=' in a line, which
    # garbles Ansible host lines like:
    #   capsule-lb-c.example.com  public_mac=aa:bb  private_ip=10.0.0.1
    # Parsing the raw text avoids that quirk.
    _host_vars: Dict[str, Dict[str, str]] = {}  # hostname → {key: val}
    _in_vars_section = False
    for line in raw.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith('['):
            section_name = stripped[1:stripped.index(']')]
            # Skip [group:vars] / [group:children] sections — only host lines matter
            _in_vars_section = ':' in section_name
            continue
        if _in_vars_section or stripped.startswith((';', '#')):
            continue
        parts = stripped.split()
        hostname = parts[0]
        hvars = {k: v.strip("'\"")
                 for part in parts[1:]
                 if '=' in part
                 for k, v in [part.split('=', 1)]}
        if hvars:
            _host_vars.setdefault(hostname, {}).update(hvars)

    hosts: List[_InventoryHost] = []
    for section in cp.sections():
        if ':' in section or section == '__root__':
            continue
        role = _ROLE_MAP.get(section)
        if role is None:
            continue
        for entry, _ in cp.items(section):
            hostname = entry.split()[0].lstrip(';#')
            if not hostname or hostname.startswith(('#', ';')):
                continue
            hosts.append(_InventoryHost(hostname, role, user, key_file, ssh_args))

    # Build IP → (role, hostname, rex_mode) topology map from per-host vars.
    # This lets _pass2 classify each session's source IP into direct/capsule/lb.
    # rex_mode defaults to 'ssh'; set to 'mqtt' on MQTT-enabled capsules.
    # Both IPv4 and IPv6 addresses are mapped: Foreman's production.log records
    # the source IP of /rhsm/consumers requests, which may be IPv6.
    topology: Dict[str, Tuple[str, str, str]] = {}  # ip → (role, hostname, rex_mode)
    for h in hosts:
        hvars = _host_vars.get(h.hostname, {})
        rex = hvars.get('rex_mode', 'ssh')
        for ip_key in ('private_ip', 'public_ip', 'private_ip6', 'public_ip6'):
            ip = hvars.get(ip_key, '')
            if ip:
                topology[ip] = (h.role, h.hostname, rex)

    return hosts, topology


def _production_log_lines_from_inventory(inv_path: str,
                                         limit_mb: int = 200) -> Iterator[str]:
    hosts, _ = _parse_inventory(inv_path)
    sats = [h for h in hosts if h.role == 'satellite']
    if not sats:
        logging.warning('No [satellite6] hosts in %s', inv_path)
        return
    for h in sats:
        # Fetch production.log (and rotated copies) if the file exists —
        # this is the standard foreman-installer / RPM-based deployment.
        # Fall back to journalctl -u foreman (rootful foremanctl, where
        # Rails logs go to stdout captured by the system journal).
        # NOTE: journalctl --user is NOT used here; rootless foremanctl
        # will be handled separately when that becomes the default.
        remote_cmd = (
            'if [ -f /var/log/foreman/production.log ]; then '
            '  for f in $(ls /var/log/foreman/production.log-* 2>/dev/null | sort) '
            '  /var/log/foreman/production.log; do '
            '    case "$f" in *.gz) zcat "$f";; *) cat "$f";; esac; '
            '  done 2>/dev/null; '
            'else '
            '  journalctl -u foreman --output=cat --no-pager 2>/dev/null; '
            'fi'
        )
        logging.info('Fetching all production.log files from %s', h.hostname)
        cmd = ['ssh']
        if h.key_file:
            cmd += ['-i', h.key_file]
        if h.ssh_args:
            cmd += shlex.split(h.ssh_args)
        cmd += [f'{h.user}@{h.hostname}', remote_cmd]
        logging.debug('SSH cmd: %s', ' '.join(cmd))
        try:
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, text=True)
            yield from proc.stdout
            proc.wait()
            if proc.returncode not in (0, 141):
                err = proc.stderr.read().strip()
                if err:
                    logging.warning('SSH %s: %s', h.hostname, err)
        except FileNotFoundError:
            logging.error('ssh binary not found in PATH')


# ---------------------------------------------------------------------------
# Parser: two-pass log → sessions
# ---------------------------------------------------------------------------

def parse_sat_cache_stats(lines: Iterator[str]) -> CacheStats:
    """Count compliance and status cache HITs/MISSes from production.log.

    Scans for lines emitted by the :registration logger (katello#11692/#11696).
    Returns CacheStats with all zeros when those PRs are absent or the logger
    is not enabled at debug level — callers must check has_data before rendering.
    """
    stats = CacheStats()
    for line in lines:
        m = _RE_LOG_LINE.match(line.rstrip('\n'))
        if not m:
            continue
        body = m.group(3)
        c = _RE_CACHE_COMPLIANCE.match(body)
        if c:
            if c.group(1) == 'HIT':
                stats.compliance_hits += 1
            else:
                stats.compliance_misses += 1
            continue
        s = _RE_CACHE_STATUS.match(body)
        if s:
            if s.group(1) == 'HIT':
                stats.status_hits += 1
            else:
                stats.status_misses += 1
    return stats


def parse_proxy_cache_stats(lines: Iterator[str]) -> CacheStats:
    """Count registration_script cache HITs/MISSes from proxy.log.

    Scans for lines emitted by foreman-proxy (smart-proxy#935) at INFO level.
    Returns CacheStats with all zeros when that PR is absent or logging was
    not at INFO — callers must check has_data before rendering.
    """
    stats = CacheStats()
    for line in lines:
        m = _RE_PROXY_LINE.match(line.rstrip('\n'))
        if not m:
            continue
        s = _RE_CACHE_SCRIPT.match(m.group(3))
        if s:
            if s.group(1) == 'HIT':
                stats.script_hits += 1
            else:
                stats.script_misses += 1
    return stats


def _pass1(lines: Iterator[str]) -> Dict[str, _Req]:
    """Extract Started/Completed pairs keyed by request ID."""
    records: Dict[str, _Req] = {}
    for line in lines:
        m = _RE_LOG_LINE.match(line.rstrip('\n'))
        if not m:
            continue
        ts_str, req_id, body = m.group(1), m.group(2), m.group(3)

        s = _RE_STARTED.match(body)
        if s and req_id not in records:
            ip_m = _RE_SOURCE_IP.search(body)
            records[req_id] = _Req(req_id, s.group(1), s.group(2),
                                   _parse_ts(ts_str),
                                   source_ip=ip_m.group(1) if ip_m else '')
            continue

        c = _RE_COMPLETED.match(body)
        if c and req_id in records:
            records[req_id].status = int(c.group(1))
            records[req_id].duration_ms = int(c.group(2))
            continue

        # Intermediate audit line: Katello writes the consumer UUID during
        # POST /rhsm/consumers processing, tied to the same req_id.
        # This gives an exact req_id → UUID mapping with no heuristics.
        if req_id in records and not records[req_id].consumer_uuid:
            u = _RE_FACET_UUID.match(body)
            if u:
                records[req_id].consumer_uuid = u.group(1)

    return records


def _pass1_proxy(lines: Iterator[str]) -> Dict[str, '_Req']:
    """Extract Started/Finished pairs from foreman-proxy proxy.log.

    proxy.log format:
      2026-04-04T17:59:38 e3c9c5ad [I] Started GET /register activation_keys=...
      2026-04-04T17:59:38 1d83b327 [I] Finished GET /register with 200 (351.05 ms)
    """
    records: Dict[str, _Req] = {}
    for line in lines:
        m = _RE_PROXY_LINE.match(line.rstrip('\n'))
        if not m:
            continue
        ts_str, req_id, body = m.group(1), m.group(2), m.group(3)

        s = _RE_PROXY_STARTED.match(body)
        if s and req_id not in records:
            records[req_id] = _Req(req_id, s.group(1), s.group(2),
                                   _parse_ts(ts_str))
            continue

        f = _RE_PROXY_FINISHED.match(body)
        if f and req_id in records:
            records[req_id].status = int(f.group(1))
            records[req_id].duration_ms = int(float(f.group(2)))

    return records


def _pass2_proxy(records: Dict[str, '_Req'],
                 window_sec: int = 120,
                 since: Optional[datetime.datetime] = None,
                 until: Optional[datetime.datetime] = None) -> List[RegistrationSession]:
    """Build registration sessions from capsule proxy.log records.

    Anchors on POST /register (one session per proxied registration).
    GET /register (script delivery) is correlated by looking backward in time.
    No UUID, no source IP — all requests belong to this capsule.
    """
    host_regs, script_fetches = [], []

    for r in records.values():
        path = r.path.split('?')[0]
        if r.method == 'POST' and _P_REGISTER.match(path):
            host_regs.append(r)
        elif r.method == 'GET' and _P_REGISTER.match(path):
            script_fetches.append(r)

    host_regs.sort(key=lambda r: r.ts or datetime.datetime.min)
    script_fetches.sort(key=lambda r: r.ts or datetime.datetime.min)

    window = datetime.timedelta(seconds=window_sec)
    sessions: List[RegistrationSession] = []

    for hr in host_regs:
        if hr.ts is None:
            continue
        if since and hr.ts < since:
            continue
        if until and hr.ts > until:
            continue

        sess = RegistrationSession(
            consumer_uuid=hr.req_id,
            started_at=hr.ts,
            host_register_ms=hr.duration_ms,
            consumer_create_status=hr.status,
        )

        for sf in reversed(script_fetches):
            if sf.ts and (hr.ts - window) <= sf.ts <= hr.ts:
                sess.script_fetch_ms = sf.duration_ms
                break

        sessions.append(sess)

    return sessions


def _pass2(records: Dict[str, _Req],
           window_sec: int = 120,
           topology: Optional[Dict[str, Tuple[str, str, str]]] = None,
           since: Optional[datetime.datetime] = None,
           until: Optional[datetime.datetime] = None) -> List[RegistrationSession]:
    """Group request records into per-registration sessions."""
    creates, script_fetches, host_regs = [], [], []
    compliance, status_calls, fact_updates, consumer_gets = [], [], [], []

    for r in records.values():
        path = r.path.split('?')[0]
        if r.method == 'POST' and _P_CONSUMER_CREATE.match(path):
            creates.append(r)
        elif r.method == 'GET' and _P_REGISTER.match(path):
            script_fetches.append(r)
        elif r.method == 'POST' and _P_REGISTER.match(path):
            host_regs.append(r)
        elif _P_COMPLIANCE.match(path):
            compliance.append(r)
        elif r.method == 'GET' and _P_STATUS.match(path):
            status_calls.append(r)
        elif r.method == 'PUT' and _P_CONSUMER_ID.match(path):
            fact_updates.append(r)
        elif r.method == 'GET' and _P_CONSUMER_ID.match(path):
            consumer_gets.append(r)

    def _sort(lst):
        lst.sort(key=lambda r: r.ts or datetime.datetime.min)

    for lst in [creates, script_fetches, host_regs,
                compliance, status_calls, fact_updates, consumer_gets]:
        _sort(lst)

    # Pre-build UUID → compliance call list so each session can look up its own
    # calls by UUID without window overlap contamination.
    uuid_compliance: Dict[str, List] = collections.defaultdict(list)
    for c in compliance:
        m = _RE_CONSUMER_UUID.search(c.path)
        if m:
            uuid_compliance[m.group(1)].append(c)


    window = datetime.timedelta(seconds=window_sec)
    sessions: List[RegistrationSession] = []

    # Pre-build sorted timestamp arrays for O(log n) bisect lookups.
    # Each list is already sorted by _sort(); None timestamps → datetime.min.
    _MIN = datetime.datetime.min

    def _ts(r):
        return r.ts if r.ts is not None else _MIN
    sf_times         = [_ts(r) for r in script_fetches]
    hr_times         = [_ts(r) for r in host_regs]
    fu_times         = [_ts(r) for r in fact_updates]
    cr_times         = [_ts(r) for r in creates]
    st_times         = [_ts(r) for r in status_calls]
    compliance_times = [_ts(r) for r in compliance]

    for create in creates:
        if create.ts is None:
            continue
        if since and create.ts < since:
            continue
        if until and create.ts > until:
            continue
        t0 = create.ts
        t1 = t0 + window
        # Pre-compute window indices for fact_updates — needed by UUID fallback
        # and also reused later for the fact_update_ms assignment.
        fu_lo = bisect.bisect_left(fu_times, t0)
        fu_hi = bisect.bisect_right(fu_times, t1)

        # Discover the UUID for this consumer create.
        #
        # Primary (exact): the audit log writes a SubscriptionFacet line with
        # the UUID during POST /rhsm/consumers, sharing the same req_id.
        # _pass1() extracts this into create.consumer_uuid — use it directly.
        #
        # Fallback: when the audit line is absent (older Foreman, redacted logs,
        # or non-standard deployments), look for the UUID in compliance or
        # fact-update paths within the session window.
        uuid = create.consumer_uuid  # exact — populated by _pass1() from audit log

        if not uuid:
            # Fallback: scan only compliance calls in [t0, t1] using bisect.
            # compliance_times is built below; reuse fu_times already available.
            c_lo = bisect.bisect_left(compliance_times, t0)
            c_hi = bisect.bisect_right(compliance_times, t1)
            for r in compliance[c_lo:c_hi]:
                m = _RE_CONSUMER_UUID.search(r.path)
                if m:
                    uuid = m.group(1)
                    break

        if not uuid:
            # Reuse fu_times (already built) to limit the scan.
            for r in fact_updates[fu_lo:fu_hi]:
                m = _RE_CONSUMER_UUID.search(r.path)
                if m:
                    uuid = m.group(1)
                    break

        if not uuid:
            uuid = 'unknown'

        # Classify routing from the source IP of the consumer create request.
        src_ip = create.source_ip
        routing, rex_mode = 'direct', 'ssh'
        if topology and src_ip in topology:
            role, hostname, rex_mode = topology[src_ip]
            routing = f'{"lb" if role == "lb" else "capsule"}:{hostname}'

        sess = RegistrationSession(
            consumer_uuid=uuid,
            started_at=t0,
            consumer_create_req_id=create.req_id,
            consumer_create_ms=create.duration_ms,
            consumer_create_status=create.status,
            source_ip=src_ip,
            routing=routing,
            rex_mode=rex_mode,
        )

        # Script fetch: nearest GET /register just before this consumer create.
        # bisect to find the rightmost sf with ts ≤ t0, then check the window.
        sf_hi = bisect.bisect_right(sf_times, t0)
        sf_lo = bisect.bisect_left(sf_times, t0 - window)
        if sf_lo < sf_hi:
            sess.script_fetch_ms = script_fetches[sf_hi - 1].duration_ms

        # Host register: first POST /register in [t0, t1].
        hr_lo = bisect.bisect_left(hr_times, t0)
        hr_hi = bisect.bisect_right(hr_times, t1)
        if hr_lo < hr_hi:
            sess.host_register_ms = host_regs[hr_lo].duration_ms

        # Fact update: first PUT /rhsm/consumers/:id in [t0, t1].
        # fu_lo/fu_hi already computed before UUID discovery.
        if fu_lo < fu_hi:
            sess.fact_update_ms = fact_updates[fu_lo].duration_ms

        # Compliance calls: look up by UUID — every call for this UUID is counted
        # regardless of window, since UUID uniquely identifies the session.
        if uuid != 'unknown':
            sess.compliance_calls = len(uuid_compliance[uuid])

        # Status calls: global endpoint with no UUID — apportion by dividing
        # total calls in window by number of concurrent sessions.
        # Both counts now use bisect instead of O(n) scans.
        cr_lo = bisect.bisect_left(cr_times, t0)
        cr_hi = bisect.bisect_right(cr_times, t1)
        concurrent = max(1, cr_hi - cr_lo)
        st_lo = bisect.bisect_left(st_times, t0)
        st_hi = bisect.bisect_right(st_times, t1)
        sess.status_calls = round((st_hi - st_lo) / concurrent)

        # Redundant GET /consumers/:id calls for this UUID (should be 0 after #11694)
        if uuid != 'unknown':
            sess.redundant_consumer_gets = sum(
                1 for g in consumer_gets
                if g.ts and t0 <= g.ts <= t1 and uuid in g.path
            )

        sessions.append(sess)

    return sessions


def _build_metrics(sessions: List[RegistrationSession],
                   label: str) -> Metrics:
    if not sessions:
        return Metrics(source_label=label, window_start=None,
                       window_end=None, session_count=0)

    timestamps = [s.started_at for s in sessions if s.started_at]
    errors = [s for s in sessions if s.consumer_create_status not in (0, 200, 201)]
    breakdown: Dict[str, int] = {}
    for s in errors:
        et = _error_type(s.consumer_create_status)
        breakdown[et] = breakdown.get(et, 0) + 1
    # Status 0 means no Completed line found (timeout or log truncation)
    timeouts = sum(1 for s in sessions
                   if s.consumer_create_ms == 0 and s.consumer_create_status == 0)
    if timeouts:
        breakdown['timeout/no-response'] = breakdown.get('timeout/no-response', 0) + timeouts

    return Metrics(
        source_label=label,
        window_start=min(timestamps) if timestamps else None,
        window_end=max(timestamps) if timestamps else None,
        session_count=len(sessions),
        error_count=len(errors) + timeouts,
        error_breakdown=breakdown,
        consumer_create_ms=[s.consumer_create_ms for s in sessions if s.consumer_create_ms],
        script_fetch_ms=[s.script_fetch_ms for s in sessions if s.script_fetch_ms],
        host_register_ms=[s.host_register_ms for s in sessions if s.host_register_ms],
        fact_update_ms=[s.fact_update_ms for s in sessions if s.fact_update_ms],
        compliance_calls=[s.compliance_calls for s in sessions],
        status_calls=[s.status_calls for s in sessions],
        redundant_consumer_gets=[s.redundant_consumer_gets for s in sessions],
    )


def analyze_proxy(lines: Iterator[str], label: str, window_sec: int = 120,
                  since: Optional[datetime.datetime] = None,
                  until: Optional[datetime.datetime] = None) -> 'Metrics':
    """Parse capsule proxy.log lines and return a Metrics summary.

    Only script_fetch_ms (GET /register) and host_register_ms (POST /register)
    are populated — RHSM calls are not proxied through foreman-proxy and
    therefore do not appear in proxy.log.
    """
    records = _pass1_proxy(lines)
    logging.info('%s (proxy): %d request records', label, len(records))
    sessions = _pass2_proxy(records, window_sec, since, until)
    logging.info('%s (proxy): %d registration sessions', label, len(sessions))
    return _build_metrics(sessions, label)


def _analyze(lines: Iterator[str], label: str, window_sec: int = 120,
             topology: Optional[Dict[str, Tuple[str, str, str]]] = None,
             since: Optional[datetime.datetime] = None,
             until: Optional[datetime.datetime] = None,
             ) -> Dict[str, 'Metrics']:
    """Parse lines and return a dict of group_label → Metrics.

    Groups are:
      "Satellite (ssh)"              – direct registrations to the Satellite
      "Standalone capsules (ssh)"    – individual capsules, push-mode REX
      "Standalone capsules (mqtt)"   – individual capsules, pull-mode REX
      "Load-balanced capsules (ssh)" – registrations via an HAproxy/LB node
                                       (LB + MQTT is unsupported)
    When there is only one group, the dict has a single entry labelled by source.
    """
    records = _pass1(lines)
    logging.info('%s: %d request records', label, len(records))
    sessions = _pass2(records, window_sec, topology, since, until)
    logging.info('%s: %d registration sessions', label, len(sessions))

    def _category(s: RegistrationSession) -> str:
        if s.routing == 'direct':
            return 'Satellite (ssh)'
        if s.routing.startswith('lb:'):
            return 'Load-balanced capsules (ssh)'
        if s.rex_mode == 'mqtt':
            return 'Standalone capsules (mqtt)'
        return 'Standalone capsules (ssh)'

    groups: Dict[str, List[RegistrationSession]] = collections.defaultdict(list)
    for s in sessions:
        groups[_category(s)].append(s)

    if len(groups) <= 1:
        return {label: _build_metrics(sessions, label)}

    # Preserve a meaningful display order
    order = ['Satellite (ssh)', 'Standalone capsules (ssh)',
             'Standalone capsules (mqtt)', 'Load-balanced capsules (ssh)']
    result = {}
    for cat in order:
        if cat not in groups:
            continue
        group_sessions = groups[cat]
        group_label = f'{label}  →  {cat}'
        result[group_label] = _build_metrics(group_sessions, group_label)
    return result


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

def _fmt_pct(vals: List[int]) -> str:
    if not vals:
        return '       -        -        -'
    p50, p95, p99 = _p50_p95_p99(vals)
    return f'{p50:>8,}  {p95:>8,}  {p99:>8,}'


def _fmt_avg(vals: List[int]) -> str:
    return f'{_avg(vals):.1f}' if vals else '-'


def print_metrics(m: Metrics) -> None:
    if m.session_count == 0:
        print(f'\nNo registration sessions found in: {m.source_label}')
        return
    w0 = m.window_start.strftime('%Y-%m-%d %H:%M:%S') if m.window_start else '?'
    w1 = m.window_end.strftime('%Y-%m-%d %H:%M:%S') if m.window_end else '?'
    print()
    print('Registration Metrics Summary')
    print('=' * 70)
    print(f'Source:   {m.source_label}')
    print(f'Window:   {w0}  →  {w1}')
    print(f'Sessions: {m.session_count:,} registrations analyzed')
    if m.error_count:
        pct_err = m.error_count / m.session_count * 100
        print(f'Errors:   {m.error_count:,} consumer create failures ({pct_err:.1f}%)')
        for etype, count in sorted(m.error_breakdown.items()):
            print(f'            {etype}: {count}')
    print()
    print(f'  {"Per-request timings (ms)":<42}   {"P50":>8}   {"P95":>8}   {"P99":>8}')
    print('  ' + '-' * 68)
    print(f'  {"POST /rhsm/consumers (consumer create)":<42} {_fmt_pct(m.consumer_create_ms)}')
    print(f'  {"GET  /register (script delivery)":<42} {_fmt_pct(m.script_fetch_ms)}')
    print(f'  {"POST /register (host record)":<42} {_fmt_pct(m.host_register_ms)}')
    print(f'  {"PUT  /rhsm/consumers/:id (fact update)":<42} {_fmt_pct(m.fact_update_ms)}')
    print()
    print(f'  {"Per-registration call counts (avg/session)":<42}   {"Avg":>8}   {"Note"}')
    print('  ' + '-' * 68)
    print(f'  {"GET /compliance calls":<42} {_fmt_avg(m.compliance_calls):>8}   '
          f'target: 1 (katello#11692)')
    print(f'  {"GET /rhsm/status calls":<42} {_fmt_avg(m.status_calls):>8}   '
          f'target: 1 (katello#11696)')
    print(f'  {"GET /rhsm/consumers/:id (redundant)":<42} {_fmt_avg(m.redundant_consumer_gets):>8}   '
          f'target: 0 (katello#11694)')
    print()


def print_comparison(before: Metrics, after: Metrics) -> None:
    print()
    print('Comparison')
    print(f'  Before: {before.source_label}  ({before.session_count:,} sessions)')
    print(f'  After:  {after.source_label}  ({after.session_count:,} sessions)')
    print('=' * 80)
    print(f'  {"Metric":<46} {"Before":>8}   {"After":>8}   {"Change":>8}   PR')
    print('  ' + '-' * 76)

    def row(label: str, bvals: List[int], avals: List[int],
            stat: str, unit: str, pr: str = '') -> None:
        if stat == 'p50':
            bv, av = _pct(bvals, 50), _pct(avals, 50)
        elif stat == 'p99':
            bv, av = _pct(bvals, 99), _pct(avals, 99)
        else:
            bv = round(_avg(bvals), 1)
            av = round(_avg(avals), 1)

        if bv == 0:
            ch, icon = 'n/a', ' '
        else:
            d = (av - bv) / bv * 100
            ch = f'{d:+.1f}%'
            icon = '✓' if d < -5 else ('✗' if d > 5 else '~')

        print(f'  {label:<46} {bv:>8} {unit}  {av:>8} {unit}  {ch:>8}   {icon} {pr}')

    row('Consumer create P50', before.consumer_create_ms,
        after.consumer_create_ms, 'p50', 'ms', 'foreman#10942 + katello#11701')
    row('Consumer create P99', before.consumer_create_ms,
        after.consumer_create_ms, 'p99', 'ms')
    row('Script delivery P99', before.script_fetch_ms,
        after.script_fetch_ms, 'p99', 'ms', 'smart-proxy#935')
    row('Host register P50', before.host_register_ms,
        after.host_register_ms, 'p50', 'ms')
    row('Fact update P50', before.fact_update_ms,
        after.fact_update_ms, 'p50', 'ms')
    row('Compliance calls/session avg', before.compliance_calls,
        after.compliance_calls, 'avg', '  ', 'katello#11692')
    row('Status calls/session avg', before.status_calls,
        after.status_calls, 'avg', '  ', 'katello#11696')
    row('Redundant GET /consumers avg', before.redundant_consumer_gets,
        after.redundant_consumer_gets, 'avg', '  ', 'katello#11694')
    print()


def _metrics_to_dict(m: Metrics) -> dict:
    def stats(vals: List[int]) -> dict:
        if not vals:
            return {'count': 0, 'p50': 0, 'p95': 0, 'p99': 0, 'avg': 0}
        p50, p95, p99 = _p50_p95_p99(vals)
        return {'count': len(vals), 'p50': p50, 'p95': p95, 'p99': p99,
                'avg': round(_avg(vals), 2)}
    return {
        'source': m.source_label,
        'window_start': m.window_start.isoformat() if m.window_start else None,
        'window_end': m.window_end.isoformat() if m.window_end else None,
        'session_count': m.session_count,
        'error_count': m.error_count,
        'error_breakdown': m.error_breakdown,
        'consumer_create_ms': stats(m.consumer_create_ms),
        'script_fetch_ms': stats(m.script_fetch_ms),
        'host_register_ms': stats(m.host_register_ms),
        'fact_update_ms': stats(m.fact_update_ms),
        'compliance_calls': stats(m.compliance_calls),
        'status_calls': stats(m.status_calls),
        'redundant_consumer_gets': stats(m.redundant_consumer_gets),
    }


# ---------------------------------------------------------------------------
# Redis/Valkey cache stats (optional, inventory mode only)
# ---------------------------------------------------------------------------

def _fetch_cache_stats(hosts: List['_InventoryHost']) -> Optional[dict]:
    """SSH to the first LB host and query redis-cli INFO for cache metrics.

    Returns a dict with keyspace_hits, keyspace_misses, connected_clients,
    and hit_rate, or None if no LB host is available or redis-cli fails.
    """
    lbs = [h for h in hosts if h.role == 'lb']
    if not lbs:
        return None

    h = lbs[0]
    cmd = ['ssh']
    if h.key_file:
        cmd += ['-i', h.key_file]
    if h.ssh_args:
        cmd += shlex.split(h.ssh_args)
    cmd += [f'{h.user}@{h.hostname}',
            'redis-cli INFO stats keyspace clients 2>/dev/null || '
            'valkey-cli INFO stats keyspace clients 2>/dev/null']

    logging.debug('Cache stats cmd: %s', ' '.join(cmd))
    try:
        out = subprocess.check_output(cmd, text=True, timeout=10)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, FileNotFoundError) as e:
        logging.warning('Could not fetch cache stats from %s: %s', h.hostname, e)
        return None

    stats: dict = {}
    for line in out.splitlines():
        line = line.strip()
        if ':' not in line or line.startswith('#'):
            continue
        key, _, val = line.partition(':')
        stats[key.strip()] = val.strip()

    hits = int(stats.get('keyspace_hits', 0))
    misses = int(stats.get('keyspace_misses', 0))
    total = hits + misses
    return {
        'host': h.hostname,
        'keyspace_hits': hits,
        'keyspace_misses': misses,
        'connected_clients': int(stats.get('connected_clients', 0)),
        'hit_rate': f'{hits / total * 100:.1f}%' if total else 'n/a (cold)',
        'db0': stats.get('db0', 'empty'),
    }


def print_cache_stats(stats: dict) -> None:
    """Print Redis/Valkey cache statistics section."""
    print()
    print('Registration Script Cache Stats')
    print('=' * 70)
    print(f'Source:  {stats["host"]} (redis-cli INFO)')
    print(f'  Hits:             {stats["keyspace_hits"]:>10,}')
    print(f'  Misses:           {stats["keyspace_misses"]:>10,}')
    print(f'  Hit rate:         {stats["hit_rate"]:>10}')
    print(f'  Connected nodes:  {stats["connected_clients"]:>10}  (capsule nodes using this cache)')
    print(f'  Keys (db0):       {stats["db0"]:>10}  (one per distinct registration parameter set)')
    print()


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )

    src = parser.add_mutually_exclusive_group()
    src.add_argument('-i', '--inventory', metavar='FILE',
                     help='Ansible INI inventory; SSH to satellite6 hosts')
    src.add_argument('--sosreport', metavar='PATH',
                     help='Single sosreport .tar.xz or extracted directory')
    src.add_argument('--sosreport-dir', metavar='PATH_OR_URL',
                     help='Directory/URL containing multiple sosreport archives')
    src.add_argument('-l', '--log', metavar='FILE',
                     help='Direct path to production.log (plain or .gz)')
    src.add_argument('--compare', nargs=2, metavar=('BEFORE', 'AFTER'),
                     help='Compare two sources (same formats as --sosreport-dir)')

    parser.add_argument('--since', metavar='EPOCH', type=float,
                        help='Only include sessions starting at or after this Unix epoch')
    parser.add_argument('--until', metavar='EPOCH', type=float,
                        help='Only include sessions starting at or before this Unix epoch')
    parser.add_argument('--json', action='store_true',
                        help='Output JSON instead of text table')
    parser.add_argument('--log-size-limit', metavar='MB', type=int, default=200,
                        help='Max MB to tail from remote logs via SSH (default: 200)')
    parser.add_argument('--window', metavar='SECONDS', type=int, default=120,
                        help='Time window to associate calls to a session (default: 120)')
    parser.add_argument('-v', '--verbose', action='store_true',
                        help='Enable debug logging to stderr')
    parser.add_argument('--cache-stats', action='store_true',
                        help='Query Redis/Valkey cache stats from LB host (--inventory only)')
    parser.add_argument('--no-verify-ssl', action='store_true',
                        help='Disable SSL certificate verification (for internal self-signed certs)')

    args = parser.parse_args()

    if args.no_verify_ssl:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        _HTTP_OPTS['context'] = ctx
        logging.getLogger().warning('SSL verification disabled')

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.WARNING,
        format='%(levelname)s: %(message)s',
        stream=sys.stderr,
    )

    if args.compare:
        before_src, after_src = args.compare
        before_groups = _analyze(_lines_for_source(before_src, args.log_size_limit),
                                 before_src, args.window)
        after_groups = _analyze(_lines_for_source(after_src, args.log_size_limit),
                                after_src, args.window)
        # For comparison, use the first (or only) group from each source
        before_m = next(iter(before_groups.values()))
        after_m = next(iter(after_groups.values()))
        if args.json:
            print(json.dumps({'before': _metrics_to_dict(before_m),
                               'after': _metrics_to_dict(after_m)}, indent=2))
        else:
            for m in before_groups.values():
                print_metrics(m)
            for m in after_groups.values():
                print_metrics(m)
            print_comparison(before_m, after_m)
        return

    since_dt = (datetime.datetime.utcfromtimestamp(args.since)
                if args.since else None)
    until_dt = (datetime.datetime.utcfromtimestamp(args.until)
                if args.until else None)

    # Single source — topology only available from inventory
    topology: Optional[Dict[str, Tuple[str, str, str]]] = None
    if args.inventory:
        hosts, topology = _parse_inventory(args.inventory)
        sats = [h for h in hosts if h.role == 'satellite']
        capsules = [h for h in hosts if h.role in ('capsule', 'lb')]
        logging.info('Inventory: %d satellites, %d capsules/lbs',
                     len(sats), len(capsules))
        lines = _production_log_lines_from_inventory(args.inventory,
                                                     args.log_size_limit)
        label = args.inventory
    elif args.sosreport:
        lines = _lines_for_source(args.sosreport, args.log_size_limit)
        label = args.sosreport
    elif args.sosreport_dir:
        lines = _production_log_lines_from_dir(args.sosreport_dir)
        label = args.sosreport_dir
    elif args.log:
        lines = _lines_from_file(args.log)
        label = args.log
    else:
        parser.error(
            'Specify one of: --inventory, --sosreport, --sosreport-dir, --log, --compare'
        )
        return

    groups = _analyze(lines, label, args.window, topology, since_dt, until_dt)
    if args.json:
        result = {k: _metrics_to_dict(v) for k, v in groups.items()}
        if args.inventory and args.cache_stats:
            cache_stats = _fetch_cache_stats(hosts)
            if cache_stats:
                result['cache_stats'] = cache_stats
        print(json.dumps(result, indent=2))
    else:
        for m in groups.values():
            print_metrics(m)
        if args.inventory and args.cache_stats:
            cache_stats = _fetch_cache_stats(hosts)
            if cache_stats:
                print_cache_stats(cache_stats)


if __name__ == '__main__':
    main()
