"""
common.py - Shared utilities for all registration analysis scripts.

Provides:
  - ConcurrencyWindow  dataclass (one test run at a given concurrent_total)
  - RunData            dataclass (everything loaded from one test run)
  - parse_measurement_log()  — parse measurement.log → windows + versions
  - _list_sosreports()       — HTTP directory listing of .tar.xz archives
  - _classify_sosreports()   — split archives into satellite vs capsule URLs
  - _lb_locations_from_topology() — location letters that have an LB in inventory
  - _filter_reg_records()    — drop non-registration requests before analysis
  - _classify_backend()      — map request path → backend service label
  - _topo_category()         — classify a session as direct/standalone/lb
  - _assign_concurrency()    — find which window a session belongs to
  - _fmt_ts()                — datetime → ISO string with milliseconds
  - configure_ssl()          — apply --no-verify-ssl to the shared HTTP context
  - load_run_data()          — one-stop loader for satellite + capsule data
"""

import datetime
import logging
import re
import ssl
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple

# registration_metrics is a sibling module
sys.path.insert(0, str(Path(__file__).parent))
import registration_metrics as rm

# ---------------------------------------------------------------------------
# Shared HTTP state — call configure_ssl(True) before any network access
# ---------------------------------------------------------------------------

_HTTP_OPTS: dict = {}


def configure_ssl(no_verify: bool = False) -> None:
    """Disable SSL certificate verification (for self-signed internal certs)."""
    if no_verify:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        _HTTP_OPTS['context'] = ctx
        rm._HTTP_OPTS.update(_HTTP_OPTS)


def _urlopen(url: str):
    import urllib.request
    return urllib.request.urlopen(url, **_HTTP_OPTS)


# ---------------------------------------------------------------------------
# ConcurrencyWindow — one concurrent_total test run
# ---------------------------------------------------------------------------

@dataclass
class ConcurrencyWindow:
    level: int           # concurrent_total value
    passed: int          # first-try successes (retry_failed=true excluded)
    failed: int          # first-try failures
    avg_duration_s: float
    since: float         # Unix epoch start of registration phase
    until: float         # Unix epoch end of registration phase

    @property
    def success_pct(self) -> float:
        total = self.passed + self.failed
        return self.passed / total * 100 if total else 0.0

    @property
    def window_s(self) -> float:
        return self.until - self.since

    @property
    def reg_per_s(self) -> float:
        """First-try successes per second — flat at saturation, the key metric."""
        return self.passed / self.window_s if self.window_s > 0 else 0.0

    @property
    def since_dt(self) -> datetime.datetime:
        return datetime.datetime.utcfromtimestamp(self.since)

    @property
    def until_dt(self) -> datetime.datetime:
        return datetime.datetime.utcfromtimestamp(self.until)


# ---------------------------------------------------------------------------
# measurement.log parsing
# ---------------------------------------------------------------------------

_RE_MLOG_REG = re.compile(
    r"experiment/reg-average\.py 'Execute registration' "
    r"'[^']*/(50-concurrent-exec-(\d+)\.log)',"
    r"[^,]*,"                       # output file
    r"0,"                           # rc
    r"(\d+(?:\.\d+)?),"             # since epoch
    r"(\d+(?:\.\d+)?),"             # until epoch
    r"[^,]*,"                       # katello version
    r"(\S+?),"                      # satellite version RPM NEVRA
    r"[^,]*,"                       # run label
    r"results\.items\.duration=\S+ results\.items\.passed=(\d+)",
)


def parse_measurement_log(run_url: str) -> Tuple[List[ConcurrencyWindow], str, str]:
    """Return (windows, sat_version, katello_version) from measurement.log."""
    url = run_url.rstrip('/') + '/measurement.log'
    logging.info('Fetching %s', url)
    try:
        with _urlopen(url) as resp:
            content = resp.read().decode('utf-8', errors='replace')
    except Exception as exc:
        logging.error('Cannot fetch measurement.log: %s', exc)
        return [], 'unknown', 'unknown'

    windows: List[ConcurrencyWindow] = []
    sat_ver = 'unknown'
    katello_ver = 'unknown'

    for line in content.splitlines():
        m = _RE_MLOG_REG.search(line)
        if not m:
            continue
        level = int(m.group(2))
        since = float(m.group(3))
        until = float(m.group(4))
        sat_raw = m.group(5)
        passed = int(m.group(6))

        sv = re.search(r'satellite-([\d\.]+)', sat_raw)
        if sv:
            sat_ver = sv.group(1)
        kv = re.search(r'katello-([\d\.]+)', line)
        if kv:
            katello_ver = kv.group(1)

        dur_m = re.search(r'results\.items\.avg_duration=(\S+)', line)
        avg_dur = float(dur_m.group(1)) if dur_m else 0.0

        windows.append(ConcurrencyWindow(
            level=level,
            passed=passed,
            failed=max(0, level - passed),
            avg_duration_s=avg_dur,
            since=since,
            until=until,
        ))

    windows.sort(key=lambda w: w.level)
    # Deduplicate: keep the first occurrence of each level
    seen: Set[int] = set()
    unique: List[ConcurrencyWindow] = []
    for w in windows:
        if w.level not in seen:
            seen.add(w.level)
            unique.append(w)
    logging.info('Parsed %d concurrency windows', len(unique))
    return unique, sat_ver, katello_ver


# ---------------------------------------------------------------------------
# Sosreport discovery
# ---------------------------------------------------------------------------

def _list_sosreports(run_url: str) -> Dict[str, str]:
    """Return {tarball_filename: full_url} for all .tar.xz in the sosreport dir."""
    url = run_url.rstrip('/') + '/sosreport/'
    try:
        with _urlopen(url) as resp:
            html = resp.read().decode('utf-8', errors='replace')
    except Exception as exc:
        logging.error('Cannot list sosreport dir %s: %s', url, exc)
        return {}

    from urllib.parse import urlparse
    result: Dict[str, str] = {}
    for href in re.findall(r'href="([^"]+\.tar\.xz)"', html):
        name = href.split('/')[-1]
        if href.startswith(('http://', 'https://')):
            full = href
        elif href.startswith('/'):
            p = urlparse(url)
            full = f'{p.scheme}://{p.netloc}{href}'
        else:
            full = url + href
        result[name] = full
    logging.info('Found %d sosreport archives', len(result))
    return result


def _classify_sosreports(archives: Dict[str, str]) -> Tuple[
        Optional[str], Dict[str, str]]:
    """Split archive dict into (satellite_url, {capsule_name: url}).

    Recognises:
      sosreport-satellite-*           → satellite
      sosreport-capsule-a-1-*         → standalone capsule
      sosreport-capsule-lb-d-*        → LB host (HAProxy) — new in future runs
    """
    satellite_url: Optional[str] = None
    capsules: Dict[str, str] = {}
    for name, url in archives.items():
        # Match satellite, capsule-X-N, or capsule-lb-X
        m = re.match(r'sosreport-(satellite|capsule-lb-[a-z]|capsule-[a-z]-\d+)-', name)
        if not m:
            continue
        role = m.group(1)
        if role == 'satellite':
            satellite_url = url
        else:
            capsules[role] = url
    return satellite_url, capsules


# ---------------------------------------------------------------------------
# Record filtering
# ---------------------------------------------------------------------------

_REG_PATTERNS = [
    rm._P_CONSUMER_CREATE, rm._P_COMPLIANCE, rm._P_STATUS,
    rm._P_CONSUMER_ID, rm._P_REGISTER,
]


def _filter_reg_records(records: Dict) -> Dict:
    """Return only registration-relevant request records.

    Reduces 1.27M satellite production.log records to ~400K by dropping
    content-view, sync, task, and other non-registration API calls.
    """
    result = {}
    for req_id, r in records.items():
        path = r.path.split('?')[0]
        if any(pat.match(path) for pat in _REG_PATTERNS):
            result[req_id] = r
    return result


# ---------------------------------------------------------------------------
# Topology classification
# ---------------------------------------------------------------------------

_TOPO_ORDER = ['Direct (satellite)', 'Standalone capsules', 'Load-balanced capsules']

# Short labels used in filters and output keys
TOPO_DIRECT = 'direct'
TOPO_STANDALONE = 'standalone-capsule'
TOPO_LB = 'lb-capsule'

# Display labels (matching _TOPO_ORDER)
_TOPO_DISPLAY = {
    TOPO_DIRECT: 'Direct (satellite)',
    TOPO_STANDALONE: 'Standalone capsules',
    TOPO_LB: 'Load-balanced capsules',
}


def _lb_locations_from_topology(topology: Optional[Dict]) -> Set[str]:
    """Return location letters (e.g. {'d'}) whose capsule-X-N nodes serve as LB backends.

    Naming convention: 'capsule-lb-X' is the HAProxy front-end for location X,
    so 'capsule-X-N' backend nodes should be classified as load-balanced.
    """
    if not topology:
        return set()
    locations: Set[str] = set()
    for _ip, (role, hostname, _rex) in topology.items():
        if role == 'lb':
            m = re.match(r'capsule-lb-([a-z])', hostname)
            if m:
                locations.add(m.group(1))
    return locations


def _topo_category(session: rm.RegistrationSession,
                   lb_locations: Set[str]) -> Tuple[str, str]:
    """Return (topo_short_label, capsule_name) for a session.

    topo_short_label: TOPO_DIRECT | TOPO_STANDALONE | TOPO_LB
    capsule_name:     e.g. 'capsule-a-1', or '' for direct
    """
    if session.routing == 'direct':
        return TOPO_DIRECT, ''
    hostname = session.routing.split(':', 1)[1] if ':' in session.routing else ''
    short = hostname.split('.')[0]  # e.g. 'capsule-a-1'
    if session.routing.startswith('lb:'):
        return TOPO_LB, short
    m = re.match(r'capsule-([a-z])-\d+', short)
    if m and m.group(1) in lb_locations:
        return TOPO_LB, short
    return TOPO_STANDALONE, short


# ---------------------------------------------------------------------------
# Backend classification
# ---------------------------------------------------------------------------

_BACKEND_PATTERNS = [
    (re.compile(r'^/rhsm/'),          'candlepin'),
    (re.compile(r'^/register$'),      'foreman'),
    (re.compile(r'^/unattended/'),    'foreman'),
    (re.compile(r'^/pulp/'),          'pulp'),
    (re.compile(r'^/redhat_access/'), 'rhcloud'),
]


def _classify_backend(path: str) -> str:
    """Map a request path (without query string) to its backend service."""
    for pattern, backend in _BACKEND_PATTERNS:
        if pattern.match(path):
            return backend
    return 'unknown'


# ---------------------------------------------------------------------------
# Window assignment
# ---------------------------------------------------------------------------

def _assign_concurrency(session: rm.RegistrationSession,
                        windows: List[ConcurrencyWindow]) -> int:
    """Return the concurrent_total level for the window containing this session.

    Returns 0 if the session falls outside all known windows.
    """
    if not session.started_at:
        return 0
    ts = session.started_at
    for w in windows:
        if w.since_dt <= ts <= w.until_dt:
            return w.level
    return 0


# ---------------------------------------------------------------------------
# Timestamp formatting
# ---------------------------------------------------------------------------

def _fmt_ts(dt: Optional[datetime.datetime]) -> str:
    """Format a datetime as ISO 8601 with millisecond precision."""
    if dt is None:
        return ''
    return dt.strftime('%Y-%m-%dT%H:%M:%S.') + f'{dt.microsecond // 1000:03d}'


# ---------------------------------------------------------------------------
# RunData — everything loaded from a single test run
# ---------------------------------------------------------------------------

@dataclass
class RunData:
    """All data loaded from one test run.

    Created by load_run_data(); passed to analysis scripts so they don't
    need to repeat the expensive satellite/capsule download-and-parse step.
    """
    run_url: str
    sat_version: str
    katello_version: str
    windows: List[ConcurrencyWindow]
    sat_url: str                       # URL of the satellite sosreport
    capsule_urls: Dict[str, str]       # {capsule_name: tarball_url}
    # Parsed from satellite production.log
    sat_records: Optional[Dict]        # {req_id: _Req}; None when load_records=False
    sat_sessions: List                 # [RegistrationSession]
    uuid_index: Dict[str, list]        # {consumer_uuid: [_Req]} for O(1) trace lookup
    # Parsed from each capsule proxy.log
    capsule_records: Dict[str, Dict]   # {capsule_name: {req_id: _Req}}
    # Topology
    topology: Optional[Dict]
    lb_locations: Set[str]
    # Cache hit/miss stats (zero when PRs not applied — check .has_data before rendering)
    sat_cache_stats: Optional[rm.CacheStats]           # from production.log
    capsule_cache_stats: Dict[str, rm.CacheStats]      # {capsule_name: CacheStats}
    # Path indexes for O(log n) lookup in _build_trace() steps 3-5
    # Each is a sorted list of (ts, req_id) for a specific method+path
    path_indexes: Dict[str, list]  # key: 'GET /register', 'POST /register', 'GET /rhsm/'


def _read_cached_lines(cache_path: Path) -> Optional[List[str]]:
    """Return lines from cache file, or None if cache miss."""
    if cache_path.exists():
        logging.info('Cache hit: %s', cache_path)
        with open(cache_path, 'r', errors='replace') as f:
            return f.readlines()
    return None


def _write_cache(cache_path: Path, lines: List[str]) -> None:
    """Write lines to cache file."""
    cache_path.parent.mkdir(parents=True, exist_ok=True)
    with open(cache_path, 'w', errors='replace') as f:
        f.writelines(lines)
    logging.info('Cached %d lines → %s', len(lines), cache_path)


# Schema versions — bump when the corresponding dataclass fields change.
_RECORDS_CACHE_VERSION  = 3  # bumped: switched from JSON to pickle
_SESSIONS_CACHE_VERSION = 2  # bumped: added sat_cache_stats to tuple


def _write_sessions_cache(cache_path: Path,
                           sessions: list,
                           uuid_index: Dict,
                           sat_cache_stats: Optional[rm.CacheStats]) -> None:
    """Persist sat_sessions + uuid_index + sat_cache_stats so _pass2() is skipped on reuse."""
    import pickle as _pickle
    cache_path.parent.mkdir(parents=True, exist_ok=True)
    with open(cache_path, 'wb') as f:
        _pickle.dump((_SESSIONS_CACHE_VERSION, sessions, uuid_index, sat_cache_stats), f,
                     protocol=_pickle.HIGHEST_PROTOCOL)
    logging.info('Sessions cache written: %d sessions → %s',
                 len(sessions), cache_path)


def _read_sessions_cache(cache_path: Path):
    """Return (sessions, uuid_index, sat_cache_stats) from cache, or (None, None, None) on miss."""
    import pickle as _pickle
    if not cache_path.exists():
        return None, None, None
    try:
        with open(cache_path, 'rb') as f:
            version, sessions, uuid_index, sat_cache_stats = _pickle.load(f)
        if version != _SESSIONS_CACHE_VERSION:
            logging.info('Sessions cache version mismatch — will re-build: %s',
                         cache_path)
            return None, None, None
        logging.info('Sessions cache hit: %d sessions ← %s',
                     len(sessions), cache_path)
        return sessions, uuid_index, sat_cache_stats
    except Exception as exc:
        logging.warning('Sessions cache load failed (%s) — will re-build', exc)
        return None, None, None


_CAP_STATS_CACHE_VERSION = 1


def _write_cap_cache_stats(cache_path: Path, stats: rm.CacheStats) -> None:
    """Persist per-capsule proxy.log cache stats to a small sidecar file."""
    import pickle as _pickle
    cache_path.parent.mkdir(parents=True, exist_ok=True)
    with open(cache_path, 'wb') as f:
        _pickle.dump((_CAP_STATS_CACHE_VERSION, stats), f,
                     protocol=_pickle.HIGHEST_PROTOCOL)
    logging.info('Capsule cache stats written → %s', cache_path)


def _read_cap_cache_stats(cache_path: Path) -> Optional[rm.CacheStats]:
    """Load per-capsule cache stats, or None on miss/stale."""
    import pickle as _pickle
    if not cache_path.exists():
        return None
    try:
        with open(cache_path, 'rb') as f:
            version, stats = _pickle.load(f)
        if version != _CAP_STATS_CACHE_VERSION:
            return None
        return stats
    except Exception:
        return None


def _write_records_cache(cache_path: Path, records: Dict) -> None:
    """Serialize a {req_id: _Req} dict to pickle for fast reloading.

    Pickle is ~5-10× faster than JSON for Python dataclass dicts of this size.
    The file is a (version, records) tuple so stale caches are detected.
    """
    import pickle as _pickle
    cache_path.parent.mkdir(parents=True, exist_ok=True)
    with open(cache_path, 'wb') as f:
        _pickle.dump((_RECORDS_CACHE_VERSION, records), f,
                     protocol=_pickle.HIGHEST_PROTOCOL)
    logging.info('Records cache written: %d records → %s', len(records), cache_path)


def _read_records_cache(cache_path: Path) -> Optional[Dict]:
    """Load a {req_id: _Req} dict from pickle cache, or None if miss/stale."""
    import pickle as _pickle
    if not cache_path.exists():
        return None
    try:
        with open(cache_path, 'rb') as f:
            version, records = _pickle.load(f)
        if version != _RECORDS_CACHE_VERSION:
            logging.info('Records cache version mismatch — will re-parse: %s', cache_path)
            return None
        logging.info('Records cache hit: %s (%d records)', cache_path, len(records))
        return records
    except Exception as exc:
        logging.warning('Records cache load failed (%s) — will re-parse', exc)
        return None


def load_run_data(run_url: str,
                  inventory: Optional[str] = None,
                  no_verify_ssl: bool = False,
                  cache_dir: Optional[str] = None,
                  load_records: bool = True) -> RunData:
    """Load all data from a test run.

    cache_dir enables a three-level cache per sosreport:
      1. sessions.pkl  — sat_sessions + uuid_index (skips _pass2, ~85s)
      2. records.pkl   — parsed _Req dict       (skips _pass1, ~90s)
      3. raw log file  — extracted log text      (skips download, ~10 min)

    load_records: if False and a sessions cache exists, sat_records is not
    loaded. Use this for analysis-only scripts that do not call _build_trace()
    (e.g. generate_registration_analysis.py). Reduces cached runs to ~10s.
    """
    configure_ssl(no_verify_ssl)
    cache = Path(cache_dir) if cache_dir else None

    # Parse topology from inventory
    topology: Optional[Dict] = None
    lb_locations: Set[str] = set()
    if inventory:
        _hosts, topology = rm._parse_inventory(inventory)
        lb_locations = _lb_locations_from_topology(topology)
        logging.info('Topology: %d IPs mapped, LB locations: %s',
                     len(topology), sorted(lb_locations))

    # Measurement log
    windows, sat_ver, katello_ver = parse_measurement_log(run_url)
    if not windows:
        raise RuntimeError('No concurrency windows found in measurement.log')

    # Discover sosreports
    archives = _list_sosreports(run_url)
    sat_url, capsule_urls = _classify_sosreports(archives)
    if not sat_url:
        raise RuntimeError('No satellite sosreport found in sosreport directory')

    logging.info('Satellite sosreport: %s', sat_url)
    for name, url in sorted(capsule_urls.items()):
        logging.info('Capsule sosreport: %s → %s', name, url)

    # Parse satellite production.log
    sat_tarball_name = sat_url.split('/')[-1].replace('.tar.xz', '')
    sat_cache  = cache / f'{sat_tarball_name}_production.log' if cache else None
    rec_cache  = cache / f'{sat_tarball_name}_records.pkl'    if cache else None
    sess_cache = cache / f'{sat_tarball_name}_sessions.pkl'   if cache else None

    # --- Try sessions cache (skips records load + _pass2 when load_records=False) ---
    sat_sessions, uuid_index, sat_cache_stats = (
        _read_sessions_cache(sess_cache) if sess_cache else (None, None, None)
    )
    sat_records: Optional[Dict] = None

    if sat_sessions is not None and not load_records:
        # Fast path: analysis-only callers skip sat_records entirely (~10s total)
        logging.info('Satellite: sessions from cache, skipping records load '
                     '(load_records=False)')
    else:
        # Load sat_records — needed for _build_trace() or as sessions cache miss
        sat_records = (rec_cache and _read_records_cache(rec_cache)) or None
        if sat_records is None:
            all_lines = (sat_cache and _read_cached_lines(sat_cache)) or None
            if all_lines is None:
                logging.info('Streaming satellite production.log (~10 min)...')
                all_lines = list(rm._production_log_lines_from_tarball(sat_url))
                if sat_cache:
                    _write_cache(sat_cache, all_lines)
            logging.info('Satellite: %d log lines', len(all_lines))
            # Parse cache stats from the raw lines before passing them to _pass1.
            # This is the only time all_lines is in memory; the result is persisted
            # in the sessions cache so subsequent runs don't need to re-read.
            if sat_cache_stats is None:
                sat_cache_stats = rm.parse_sat_cache_stats(iter(all_lines))
                logging.info('Satellite cache stats: compliance %d/%d, status %d/%d',
                             sat_cache_stats.compliance_hits,
                             sat_cache_stats.compliance_misses,
                             sat_cache_stats.status_hits,
                             sat_cache_stats.status_misses)
            all_records = rm._pass1(iter(all_lines))
            del all_lines
            logging.info('Satellite: %d total request records', len(all_records))
            sat_records = _filter_reg_records(all_records)
            del all_records
            if rec_cache:
                _write_records_cache(rec_cache, sat_records)
        elif sat_cache_stats is None and sat_cache and sat_cache.exists():
            # Records cache hit but no cache stats yet (e.g. version bump invalidated
            # sessions cache).  Re-read the raw log file — it's already on disk.
            logging.info('Satellite: re-reading raw log for cache stats...')
            raw = _read_cached_lines(sat_cache)
            if raw:
                sat_cache_stats = rm.parse_sat_cache_stats(iter(raw))
        logging.info('Satellite: %d registration-relevant records', len(sat_records))

        if sat_sessions is None:
            # Build sessions and uuid_index from scratch
            logging.info('Satellite: building sessions...')
            sat_sessions = rm._pass2(sat_records, window_sec=120, topology=topology)
            logging.info('Satellite: %d sessions', len(sat_sessions))

            uuid_index = {}
            for r in sat_records.values():
                m = rm._RE_CONSUMER_UUID.search(r.path)
                if m:
                    uid = m.group(1)
                    uuid_index.setdefault(uid, []).append(r)

            if sess_cache:
                _write_sessions_cache(sess_cache, sat_sessions, uuid_index,
                                      sat_cache_stats)
        else:
            logging.info('Satellite: %d sessions from cache (sat_records loaded '
                         'for trace building)', len(sat_sessions))

    # Parse capsule proxy.log files — same three-level cache as satellite:
    # 1. records.pkl (skip _pass1_proxy entirely)
    # 2. raw proxy.log text (skip download)
    # 3. network download
    # Per-capsule cache stats are stored in a small sidecar file alongside records.
    capsule_records: Dict[str, Dict] = {}
    capsule_cache_stats: Dict[str, rm.CacheStats] = {}
    for cap_name, cap_url in sorted(capsule_urls.items()):
        cap_tarball_name = cap_url.split('/')[-1].replace('.tar.xz', '')
        cap_rec_cache    = cache / f'{cap_tarball_name}_records.pkl'    if cache else None
        cap_line_cache   = cache / f'{cap_tarball_name}_proxy.log'      if cache else None
        cap_stats_cache  = cache / f'{cap_tarball_name}_cap_stats.pkl'  if cache else None

        cap_records = (cap_rec_cache and _read_records_cache(cap_rec_cache)) or None
        cap_stats   = (cap_stats_cache and _read_cap_cache_stats(cap_stats_cache)) or None

        if cap_records is None:
            proxy_lines = (cap_line_cache and _read_cached_lines(cap_line_cache)) or None
            if proxy_lines is None:
                logging.info('Streaming %s proxy.log...', cap_name)
                proxy_lines = list(rm.proxy_log_lines_from_tarball(cap_url))
                if cap_line_cache:
                    _write_cache(cap_line_cache, proxy_lines)
            # Parse cache stats from raw lines before _pass1_proxy consumes the iterator.
            if cap_stats is None:
                cap_stats = rm.parse_proxy_cache_stats(iter(proxy_lines))
                if cap_stats_cache:
                    _write_cap_cache_stats(cap_stats_cache, cap_stats)
            all_proxy = rm._pass1_proxy(iter(proxy_lines))
            cap_records = {
                k: v for k, v in all_proxy.items()
                if rm._P_REGISTER.match(v.path.split('?')[0])
            }
            if cap_rec_cache:
                _write_records_cache(cap_rec_cache, cap_records)
        elif cap_stats is None and cap_line_cache and cap_line_cache.exists():
            # Records cache hit but no stats yet — re-read raw log (already on disk).
            raw = _read_cached_lines(cap_line_cache)
            if raw:
                cap_stats = rm.parse_proxy_cache_stats(iter(raw))
                if cap_stats_cache:
                    _write_cap_cache_stats(cap_stats_cache, cap_stats)

        capsule_records[cap_name] = cap_records
        capsule_cache_stats[cap_name] = cap_stats or rm.CacheStats()
        logging.info('%s: %d /register records', cap_name, len(cap_records))

    # Build path indexes for O(log n) lookup in _build_trace() steps 3-5.
    # Only possible when sat_records is loaded (load_records=True).
    path_indexes: Dict[str, list] = {}
    if sat_records is not None:
        _MIN_DT = datetime.datetime.min
        for key, method, path_pat in [
            ('GET /register',  'GET',  rm._P_REGISTER),
            ('POST /register', 'POST', rm._P_REGISTER),
            ('GET /rhsm/',     'GET',  None),          # exact match below
        ]:
            entries = []
            for r in sat_records.values():
                if r.method != method:
                    continue
                p = r.path.split('?')[0]
                if path_pat:
                    if not path_pat.match(p):
                        continue
                else:
                    if p != '/rhsm/':
                        continue
                entries.append((r.ts or _MIN_DT, r.req_id))
            entries.sort()
            path_indexes[key] = entries
        logging.info('Path indexes built: %s',
                     {k: len(v) for k, v in path_indexes.items()})

    logging.info('All data loaded.')
    return RunData(
        run_url=run_url.rstrip('/'),
        sat_version=sat_ver,
        katello_version=katello_ver,
        windows=windows,
        sat_url=sat_url,
        capsule_urls=capsule_urls,
        sat_records=sat_records,
        sat_sessions=sat_sessions,
        uuid_index=uuid_index,
        capsule_records=capsule_records,
        sat_cache_stats=sat_cache_stats,
        capsule_cache_stats=capsule_cache_stats,
        topology=topology,
        lb_locations=lb_locations,
        path_indexes=path_indexes,
    )


# ---------------------------------------------------------------------------
# Cache population CLI
# ---------------------------------------------------------------------------

def populate_cache(run_url: str, cache_dir: str,
                   inventory: Optional[str] = None,
                   no_verify_ssl: bool = False) -> None:
    """Download all sosreports and populate every cache layer.

    After this completes, any subsequent analysis script run with the same
    --cache-dir will skip all network access and be significantly faster.
    """
    logging.info('Populating cache at %s …', cache_dir)
    load_run_data(run_url, inventory=inventory,
                  no_verify_ssl=no_verify_ssl, cache_dir=cache_dir)
    logging.info('Cache fully populated at %s', cache_dir)


if __name__ == '__main__':
    import argparse as _ap
    p = _ap.ArgumentParser(
        description='Populate the satperf analysis cache from a test run.\n\n'
                    'Downloads all sosreports and writes parsed record caches so\n'
                    'subsequent analysis scripts run in <60s instead of ~15 min.',
    )
    p.add_argument('--run-url', required=True, metavar='URL')
    p.add_argument('--cache-dir', required=True, metavar='DIR')
    p.add_argument('--inventory', metavar='FILE')
    p.add_argument('--no-verify-ssl', action='store_true')
    p.add_argument('-v', '--verbose', action='store_true')
    args = p.parse_args()
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format='%(levelname)s: %(message)s',
    )
    populate_cache(args.run_url, args.cache_dir,
                   inventory=args.inventory,
                   no_verify_ssl=args.no_verify_ssl)
