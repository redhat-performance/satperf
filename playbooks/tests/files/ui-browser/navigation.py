from __future__ import annotations

import json
from time import monotonic
from urllib.parse import urljoin, urlparse

from output import slugify
from scenarios import ROUTE_TO_PAGE_ID

CONTENT_SETTLE_MS = 750
CONTENT_POLL_MS = 250
GENERIC_DRILLDOWN_WAIT_MS = 5000
LINK_INSPECTION_TIMEOUT_MS = 250
ACTIVATION_DIAGNOSTIC_PREFIX = "SATPERF_ACTIVATION_DIAG "


class RequestTracker:
    def __init__(self, page):
        self._records: list[dict] = []
        self._active: dict[int, dict] = {}
        self._snapshot_baselines: dict[int, float] = {}
        page.on("request", self._on_request)
        page.on("response", self._on_response)
        page.on("requestfinished", self._on_request_finished)
        page.on("requestfailed", self._on_request_failed)

    def _on_request(self, request) -> None:
        self._active[id(request)] = {
            "url": request.url,
            "method": request.method,
            "resource_type": request.resource_type,
            "start_ms": monotonic() * 1000.0,
        }

    def _on_response(self, response) -> None:
        request = response.request
        record = self._active.get(id(request))
        if record is not None:
            record["status"] = response.status

    def _finalize(self, request, outcome: str) -> None:
        record = self._active.pop(id(request), None)
        if record is None:
            return
        end_ms = monotonic() * 1000.0
        record["outcome"] = outcome
        record["end_ms"] = end_ms
        record["duration_ms"] = round(end_ms - record["start_ms"], 2)
        if outcome == "failed":
            try:
                failure = request.failure
                if failure:
                    record["failure"] = str(failure)
            except Exception:
                pass
        self._records.append(record)

    def _on_request_finished(self, request) -> None:
        self._finalize(request, "finished")

    def _on_request_failed(self, request) -> None:
        self._finalize(request, "failed")

    def snapshot(self) -> int:
        snapshot = len(self._records)
        self._snapshot_baselines[snapshot] = monotonic() * 1000.0
        return snapshot

    @staticmethod
    def _relative_offsets(record: dict, baseline_ms: float) -> tuple[float | None, float | None]:
        start_ms = record.get("start_ms")
        end_ms = record.get("end_ms")
        if not isinstance(start_ms, (int, float)):
            return None, None
        start_offset = round(start_ms - baseline_ms, 2)
        end_offset = round(end_ms - baseline_ms, 2) if isinstance(end_ms, (int, float)) else None
        return start_offset, end_offset

    @staticmethod
    def _compute_concurrency(records: list[dict], baseline_ms: float) -> dict:
        intervals: list[tuple[float, float]] = []
        for record in records:
            start_offset, end_offset = RequestTracker._relative_offsets(record, baseline_ms)
            if start_offset is None or end_offset is None:
                continue
            intervals.append((start_offset, end_offset))

        if not intervals:
            return {
                "max_concurrent": 0,
                "peak_concurrent_at_ms": None,
                "span_ms": 0,
                "finished_requests": 0,
            }

        events: list[tuple[float, int]] = []
        for start_offset, end_offset in intervals:
            events.append((start_offset, 1))
            events.append((end_offset, -1))
        events.sort(key=lambda item: (item[0], -item[1]))

        current = 0
        max_concurrent = 0
        peak_at: float | None = None
        for offset_ms, delta in events:
            current += delta
            if current > max_concurrent:
                max_concurrent = current
                peak_at = offset_ms

        return {
            "max_concurrent": max_concurrent,
            "peak_concurrent_at_ms": round(peak_at, 2) if peak_at is not None else None,
            "span_ms": round(max(end for _, end in intervals) - min(start for start, _ in intervals), 2),
            "finished_requests": len(intervals),
        }

    def summary_since(self, snapshot: int, top_limit: int = 5, timeline_limit: int = 8) -> dict:
        records = self._records[snapshot:]
        baseline_ms = self._snapshot_baselines.get(snapshot)
        if baseline_ms is None and records:
            first_start = records[0].get("start_ms")
            baseline_ms = first_start if isinstance(first_start, (int, float)) else monotonic() * 1000.0
        elif baseline_ms is None:
            baseline_ms = monotonic() * 1000.0

        by_resource_type: dict[str, int] = {}
        for record in records:
            resource_type = record.get("resource_type") or "unknown"
            by_resource_type[resource_type] = by_resource_type.get(resource_type, 0) + 1

        enriched_records: list[dict] = []
        for record in records:
            start_offset, end_offset = self._relative_offsets(record, baseline_ms)
            enriched_records.append(
                {
                    **record,
                    "start_offset_ms": start_offset,
                    "end_offset_ms": end_offset,
                }
            )

        sorted_slowest = sorted(
            (record for record in enriched_records if isinstance(record.get("duration_ms"), (int, float))),
            key=lambda item: item["duration_ms"],
            reverse=True,
        )
        top_slowest = [
            {
                "url": record.get("url"),
                "resource_type": record.get("resource_type"),
                "status": record.get("status"),
                "outcome": record.get("outcome"),
                "duration_ms": record.get("duration_ms"),
                "start_offset_ms": record.get("start_offset_ms"),
                "end_offset_ms": record.get("end_offset_ms"),
            }
            for record in sorted_slowest[:top_limit]
        ]
        failed_requests = [
            {
                "url": record.get("url"),
                "resource_type": record.get("resource_type"),
                "status": record.get("status"),
                "failure": record.get("failure"),
                "start_offset_ms": record.get("start_offset_ms"),
                "end_offset_ms": record.get("end_offset_ms"),
            }
            for record in enriched_records
            if record.get("outcome") == "failed"
        ][:top_limit]

        timeline = sorted(
            (
                {
                    "url": record.get("url"),
                    "resource_type": record.get("resource_type"),
                    "status": record.get("status"),
                    "outcome": record.get("outcome"),
                    "duration_ms": record.get("duration_ms"),
                    "start_offset_ms": record.get("start_offset_ms"),
                    "end_offset_ms": record.get("end_offset_ms"),
                }
                for record in enriched_records
                if record.get("start_offset_ms") is not None
            ),
            key=lambda item: item["start_offset_ms"],
        )[:timeline_limit]

        start_offsets = [record["start_offset_ms"] for record in enriched_records if record.get("start_offset_ms") is not None]
        end_offsets = [record["end_offset_ms"] for record in enriched_records if record.get("end_offset_ms") is not None]
        concurrency = self._compute_concurrency(records, baseline_ms)

        return {
            "total": len(records),
            "failed": sum(1 for record in records if record.get("outcome") == "failed"),
            "api_requests": sum(1 for record in records if record.get("resource_type") in {"fetch", "xhr"}),
            "document_requests": sum(1 for record in records if record.get("resource_type") == "document"),
            "by_resource_type": by_resource_type,
            "top_slowest": top_slowest,
            "failed_samples": failed_requests,
            "sequencing": {
                "baseline_offset_ms": 0,
                "first_request_offset_ms": min(start_offsets) if start_offsets else None,
                "last_request_end_offset_ms": max(end_offsets) if end_offsets else None,
                **concurrency,
                "timeline": timeline,
            },
        }


def normalize_path(raw_url: str) -> str:
    parsed = urlparse(raw_url)
    path = parsed.path or raw_url
    if path != "/":
        path = path.rstrip("/")
    return path or "/"


def current_path(page) -> str:
    return normalize_path(page.url)


def wait_for_page_ready(page, timeout_ms: int, ready_text: str | None = None, ready_selector: str | None = None) -> None:
    if ready_selector:
        page.locator(ready_selector).first.wait_for(state="visible", timeout=timeout_ms)
    if ready_text:
        page.get_by_text(ready_text, exact=False).first.wait_for(timeout=timeout_ms)


def inspect_content_state(page) -> dict:
    return page.evaluate(
        """
        () => {
          const visible = (element) => {
            if (!element) return false;
            const style = window.getComputedStyle(element);
            const rect = element.getBoundingClientRect();
            return style &&
              style.visibility !== 'hidden' &&
              style.display !== 'none' &&
              rect.width > 0 &&
              rect.height > 0;
          };

          const roots = ['#foreman-main-container', 'main#foreman-main-container', 'main', '#foreman-page', 'body'];
          const unique = (nodes) => [...new Set(nodes)];
          const summarizeRoot = (candidate, selector) => {
            const collect = (query) => unique([...candidate.querySelectorAll(query)].filter(visible));
            const dataRows = collect("table tbody tr, table tr, [role='row']").filter((row) => row.querySelector('td,[role=\"gridcell\"]'));
            const dataLinks = collect("table tbody tr td a[href], table tr td a[href], [role='row'] a[href], .pf-v5-c-card a[href], .pf-v6-c-card a[href]");
            const cards = collect(".pf-v5-c-card, .pf-v6-c-card");
            const rowButtons = collect("table tbody tr button, table tr button, [role='row'] button, [role='row'] [role='button']");
            const textLength = ((candidate.innerText || '').trim()).length;
            return {
              selector,
              dataRows,
              dataLinks,
              cards,
              rowButtons,
              textLength,
              score: (dataRows.length * 1000) + (dataLinks.length * 100) + (cards.length * 50) + (rowButtons.length * 20) + textLength,
            };
          };

          let bestRoot = summarizeRoot(document.body, 'body');
          for (const selector of roots) {
            const candidate = document.querySelector(selector);
            if (candidate && visible(candidate)) {
              const summary = summarizeRoot(candidate, selector);
              if (summary.score >= bestRoot.score) {
                bestRoot = summary;
              }
            }
          }

          const rootSelector = bestRoot.selector;
          const dataRows = bestRoot.dataRows;
          const dataLinks = bestRoot.dataLinks;
          const cards = bestRoot.cards;
          const rowButtons = bestRoot.rowButtons;
          const headings = unique([...document.querySelectorAll('h1,h2')].filter(visible))
            .map((element) => (element.textContent || '').trim())
            .filter(Boolean)
            .slice(0, 4);
          const textLength = bestRoot.textLength;

          let readinessMode = null;
          if (dataRows.length > 0 && dataLinks.length > 0) {
            readinessMode = 'table-links';
          } else if (dataRows.length > 0) {
            readinessMode = 'table-rows';
          } else if (cards.length > 0 && dataLinks.length > 0) {
            readinessMode = 'card-links';
          } else if (cards.length > 0) {
            readinessMode = 'cards';
          } else if (textLength >= 200 && rowButtons.length > 0) {
            readinessMode = 'text-buttons';
          } else if (textLength >= 120) {
            readinessMode = 'text';
          }

          return {
            root_selector: rootSelector,
            headings,
            text_length: textLength,
            visible_rows: dataRows.length,
            visible_links: dataLinks.length,
            visible_cards: cards.length,
            visible_buttons: rowButtons.length,
            readiness_mode: readinessMode,
          };
        }
        """
    )


def classify_list_state(page, route: str | None = None) -> dict:
    content = inspect_content_state(page)
    snapshot = _capture_text_snapshot(page)
    text = (snapshot.get("text_excerpt") or "").lower()
    effective_route = normalize_path(route or current_path(page))
    empty_state_components = page.locator(
        ".pf-v5-c-empty-state, .pf-v6-c-empty-state, [data-ouia-component-type='PF5/EmptyState'], [data-ouia-component-type='PF/EmptyState']"
    ).count()

    permission_patterns = (
        "not authorized",
        "forbidden",
        "permission denied",
        "do not have permission",
        "insufficient permissions",
        "you are not allowed",
    )
    empty_patterns = (
        "no results",
        "nothing found",
        "there are no",
        "no matching",
        "0 results",
        "empty list",
        "no records",
        "no hosts found",
        "no data",
    )
    informational_empty_patterns = (
        "can run arbitrary commands on remote hosts",
        "to get started",
        "learn more",
        "using different execution methods",
    )
    informational_empty_by_route = {
        "/job_invocations": (
            "satellite can run arbitrary commands on remote hosts",
            "job invocations",
        ),
    }

    classification = "unknown"
    if any(pattern in text for pattern in permission_patterns):
        classification = "permission_restricted"
    elif empty_state_components > 0 or any(pattern in text for pattern in empty_patterns):
        classification = "empty"
    elif effective_route in informational_empty_by_route and all(
        pattern in text for pattern in informational_empty_by_route[effective_route]
    ):
        classification = "informational_empty"
    elif (
        content.get("visible_rows", 0) == 0
        and content.get("visible_links", 0) == 0
        and content.get("visible_buttons", 0) == 0
        and content.get("readiness_mode") == "text"
        and content.get("text_length", 0) >= 200
        and any(pattern in text for pattern in informational_empty_patterns)
    ):
        classification = "informational_empty"
    elif content.get("visible_links", 0) > 0:
        classification = "actionable_no_match"
    elif content.get("visible_rows", 0) == 0 and content.get("text_length", 0) < 120:
        classification = "empty"
    elif content.get("readiness_mode") is None:
        classification = "loading_incomplete"

    return {
        "classification": classification,
        "signals": {
            **content,
            "route": effective_route,
            "empty_state_components": empty_state_components,
            "text_excerpt": (snapshot.get("text_excerpt") or "")[:240],
        },
    }


def wait_for_dynamic_content(page, timeout_ms: int, ready_text: str | None = None, ready_selector: str | None = None) -> dict:
    started = monotonic()
    wait_for_page_ready(page, timeout_ms, ready_text=ready_text, ready_selector=ready_selector)
    shell_ready_ms = round((monotonic() - started) * 1000.0, 2)

    deadline = started + (timeout_ms / 1000.0)
    stable_since = None
    previous_signature = None
    latest_state = inspect_content_state(page)

    while monotonic() < deadline:
        latest_state = inspect_content_state(page)
        readiness_mode = latest_state.get("readiness_mode")
        signature = json.dumps(
            {
                "root_selector": latest_state.get("root_selector"),
                "text_length_bucket": int((latest_state.get("text_length") or 0) / 50),
                "visible_rows": latest_state.get("visible_rows"),
                "visible_links": latest_state.get("visible_links"),
                "visible_cards": latest_state.get("visible_cards"),
                "visible_buttons": latest_state.get("visible_buttons"),
                "readiness_mode": readiness_mode,
            },
            sort_keys=True,
        )

        if readiness_mode:
            if signature == previous_signature:
                stable_since = stable_since or monotonic()
            else:
                previous_signature = signature
                stable_since = monotonic()
            if stable_since and (monotonic() - stable_since) * 1000.0 >= CONTENT_SETTLE_MS:
                return {
                    "shell_ready_ms": shell_ready_ms,
                    "content_ready_ms": round((monotonic() - started) * 1000.0, 2),
                    "readiness_mode": readiness_mode,
                    "readiness_signals": latest_state,
                    "stable": True,
                }

        page.wait_for_timeout(CONTENT_POLL_MS)

    return {
        "shell_ready_ms": shell_ready_ms,
        "content_ready_ms": round((monotonic() - started) * 1000.0, 2),
        "readiness_mode": latest_state.get("readiness_mode") or "shell-only",
        "readiness_signals": latest_state,
        "stable": False,
    }


def _eligible_link(link, current_route: str, href_contains: str | None, disallowed: tuple[str, ...]) -> tuple[bool, str]:
    href = ""
    try:
        href = link.get_attribute("href", timeout=LINK_INSPECTION_TIMEOUT_MS) or ""
        if not href or not link.is_visible():
            return False, href
    except Exception:
        return False, href
    normalized_href = normalize_path(href)
    if normalized_href == current_route:
        return False, href
    if href_contains and href_contains not in href:
        return False, href
    if any(fragment in href for fragment in disallowed):
        return False, href
    if href.startswith("#") or href.lower().startswith("javascript:"):
        return False, href
    return True, href


def _find_first_matching_link(page, selector: str, current_route: str, href_contains: str | None, disallowed: tuple[str, ...]):
    candidates = page.locator(selector)
    for index in range(candidates.count()):
        link = candidates.nth(index)
        try:
            allowed, href = _eligible_link(link, current_route, href_contains, disallowed)
        except Exception:
            continue
        if allowed:
            return link, href
    return None, None


def find_drilldown_target(page, href_contains: str | None, disallowed: tuple[str, ...] = (), timeout_ms: int = GENERIC_DRILLDOWN_WAIT_MS):
    selectors = [
        "table tbody tr td a[href]",
        "table tr td a[href]",
        "[role='row'] a[href]",
        ".pf-v5-c-card a[href]",
        ".pf-v6-c-card a[href]",
        "a[href]",
    ]
    current_route = current_path(page)
    deadline = monotonic() + (timeout_ms / 1000.0)

    while monotonic() < deadline:
        for selector in selectors:
            link, href = _find_first_matching_link(page, selector, current_route, href_contains, disallowed)
            if link is not None:
                mode = "matching-link" if href_contains else "generic-link"
                if selector != "a[href]" and not href_contains:
                    mode = "row-link"
                elif selector != "a[href]" and href_contains:
                    mode = "matching-row-link"
                return link, href, mode
        page.wait_for_timeout(CONTENT_POLL_MS)

    return None, None, None


def _visible_locator(page, selector: str):
    locator = page.locator(selector)
    for index in range(locator.count()):
        candidate = locator.nth(index)
        if candidate.is_visible():
            return candidate
    return None


def _capture_text_snapshot(page) -> dict:
    return page.evaluate(
        """
        () => {
          const visible = (element) => {
            if (!element) return false;
            const style = window.getComputedStyle(element);
            const rect = element.getBoundingClientRect();
            return style &&
              style.visibility !== 'hidden' &&
              style.display !== 'none' &&
              rect.width > 0 &&
              rect.height > 0;
          };
          const roots = ['main#foreman-main-container', '#foreman-main-container', 'main', '.container-fluid', '#foreman-page', 'body'];
          let bestText = '';
          let bestSelector = 'body';
          for (const selector of roots) {
            const candidate = document.querySelector(selector);
            if (!candidate || !visible(candidate)) continue;
            const text = (candidate.innerText || '').replace(/\\s+/g, ' ').trim();
            if (text.length >= bestText.length) {
              bestText = text;
              bestSelector = selector;
            }
          }
          return {
            root_selector: bestSelector,
            text_length: bestText.length,
            text_excerpt: bestText.slice(0, 2000),
          };
        }
        """
    )


def _capture_search_snapshot(page) -> dict:
    return page.evaluate(
        """
        () => {
          const visible = (element) => {
            if (!element) return false;
            const style = window.getComputedStyle(element);
            const rect = element.getBoundingClientRect();
            return style &&
              style.visibility !== 'hidden' &&
              style.display !== 'none' &&
              rect.width > 0 &&
              rect.height > 0;
          };
          const roots = ['main#foreman-main-container', '#foreman-main-container', 'main', '.container-fluid', '#foreman-page', 'body'];
          let bestText = '';
          let bestSelector = 'body';
          for (const selector of roots) {
            const candidate = document.querySelector(selector);
            if (!candidate || !visible(candidate)) continue;
            const text = (candidate.innerText || '').replace(/\\s+/g, ' ').trim();
            if (text.length >= bestText.length) {
              bestText = text;
              bestSelector = selector;
            }
          }
          const counts = [...document.querySelectorAll('button,[role=\"button\"],span,div')]
            .filter(visible)
            .map((element) => (element.innerText || '').replace(/\\s+/g, ' ').trim())
            .filter((text) => /^\\d+\\s*-\\s*\\d+\\s+of\\s+\\d+$/i.test(text))
            .slice(0, 6);
          return {
            root_selector: bestSelector,
            text_length: bestText.length,
            text_excerpt: bestText.slice(0, 4000),
            count_labels: counts,
          };
        }
        """
    )


def perform_search_interaction(page, search_term: str, timeout_ms: int) -> dict:
    if not search_term:
        raise ValueError("search_term is required for search workflow")

    search_input = _visible_locator(page, "input[placeholder='Search']")
    if search_input is None:
        search_input = _visible_locator(page, "input[aria-label='Search input']")
    if search_input is None:
        raise RuntimeError("No visible page search input found")

    placeholder = search_input.get_attribute("placeholder") or ""
    if "Ctrl+Shift+F" in placeholder:
        raise RuntimeError("Only global search input found; page-level search input missing")

    before_snapshot = _capture_search_snapshot(page)
    search_input.fill("", timeout=min(timeout_ms, 5000))
    search_input.fill(search_term, timeout=min(timeout_ms, 5000))
    search_input.press("Enter", timeout=min(timeout_ms, 5000))
    page.wait_for_load_state("networkidle", timeout=timeout_ms)

    deadline = monotonic() + (timeout_ms / 1000.0)
    latest_snapshot = _capture_search_snapshot(page)
    while monotonic() < deadline:
        latest_snapshot = _capture_search_snapshot(page)
        text_changed = latest_snapshot.get("text_excerpt") != before_snapshot.get("text_excerpt")
        counts_changed = latest_snapshot.get("count_labels") != before_snapshot.get("count_labels")
        if text_changed or counts_changed:
            return {
                "interaction_mode": "page-search-enter",
                "search_term": search_term,
                "before": before_snapshot,
                "after": latest_snapshot,
            }
        page.wait_for_timeout(CONTENT_POLL_MS)

    raise RuntimeError(f"Search results did not stabilize for query '{search_term}'")


def _activation_targets(page, target, detail_href: str | None):
    targets = []
    if detail_href:
        targets.append(("href", page.locator(f"a[href={json.dumps(detail_href)}]").first))
    targets.append(("selected", target))
    return targets


def _wait_for_detail_route(page, expected_route: str | None, initial_route: str, timeout_ms: int) -> bool:
    deadline = monotonic() + (timeout_ms / 1000.0)
    while monotonic() < deadline:
        current_route = current_path(page)
        if expected_route:
            if current_route == expected_route:
                return True
        elif current_route != initial_route:
            return True
        page.wait_for_timeout(100)
    return False


def _js_click_href(page, detail_href: str) -> bool:
    return bool(
        page.evaluate(
            """
            (href) => {
              const visible = (element) => {
                if (!element) return false;
                const style = window.getComputedStyle(element);
                const rect = element.getBoundingClientRect();
                return style &&
                  style.visibility !== 'hidden' &&
                  style.display !== 'none' &&
                  rect.width > 0 &&
                  rect.height > 0;
              };
              const candidates = [...document.querySelectorAll('a[href]')].filter(
                (element) => element.getAttribute('href') === href && visible(element)
              );
              if (!candidates.length) {
                return false;
              }
              candidates[0].click();
              return true;
            }
            """,
            detail_href,
        )
    )



def activation_diagnostic_prefix() -> str:
    return ACTIVATION_DIAGNOSTIC_PREFIX


def start_activation_diagnostics(page, detail_href: str | None) -> dict:
    return page.evaluate(
        """
        ({ href, prefix }) => {
          const visible = (element) => {
            if (!element) return false;
            const style = window.getComputedStyle(element);
            const rect = element.getBoundingClientRect();
            return style &&
              style.visibility !== 'hidden' &&
              style.display !== 'none' &&
              rect.width > 0 &&
              rect.height > 0;
          };
          const summarize = (element) => {
            if (!element || !element.tagName) return null;
            const className =
              typeof element.className === 'string'
                ? element.className
                : (element.getAttribute && element.getAttribute('class')) || '';
            return {
              tag: element.tagName.toLowerCase(),
              id: element.id || null,
              classes: className.split(/\\s+/).filter(Boolean).slice(0, 6),
              href: element.getAttribute ? element.getAttribute('href') : null,
              text: ((element.innerText || element.textContent || '').replace(/\\s+/g, ' ').trim()).slice(0, 160),
            };
          };
          const emit = (kind, payload = {}) => {
            console.log(
              prefix +
                JSON.stringify({
                  kind,
                  t: Number((performance.now() - startedAt).toFixed(2)),
                  route: location.pathname + location.search + location.hash,
                  ...payload,
                })
            );
          };
          const findAnchor = () => {
            if (!href) return null;
            return [...document.querySelectorAll('a[href]')].find(
              (element) => element.getAttribute('href') === href && visible(element)
            ) || null;
          };

          if (window.__satperfActivationCleanup) {
            try {
              window.__satperfActivationCleanup();
            } catch (error) {
              console.warn('satperf activation cleanup failed', error);
            }
          }

          const anchor = findAnchor();
          const row = anchor ? anchor.closest('tr,[role="row"],.pf-v5-c-card,.pf-v6-c-card') : null;
          const observeRoot = row?.parentElement || row || anchor?.parentElement || anchor || document.body;
          const startedAt = performance.now();
          let mutationCount = 0;
          let routeState = location.pathname + location.search + location.hash;

          emit('start', {
            detail_href: href,
            anchor: summarize(anchor),
            row: summarize(row),
            observe_root: summarize(observeRoot),
          });

          const documentListener = (event) => {
            const path = typeof event.composedPath === 'function' ? event.composedPath() : [];
            const pathAnchor =
              path.find(
                (node) =>
                  node &&
                  node.nodeType === Node.ELEMENT_NODE &&
                  node.tagName &&
                  node.tagName.toLowerCase() === 'a' &&
                  (!href || node.getAttribute('href') === href)
              ) || null;
            const inRow = !!(row && path.some((node) => node === row || (node?.nodeType === Node.ELEMENT_NODE && row.contains(node))));
            if (!pathAnchor && !inRow) return;
            emit('dom-event', {
              event: event.type,
              button: event.button,
              detail: event.detail,
              is_trusted: !!event.isTrusted,
              target: summarize(event.target),
              matched_anchor: summarize(pathAnchor),
              in_row: inRow,
            });
          };

          for (const type of ['mousedown', 'mouseup', 'click']) {
            document.addEventListener(type, documentListener, true);
          }

          const onPopState = () => emit('popstate');
          const onHashChange = () => emit('hashchange');
          const onPageHide = () => emit('pagehide');
          const onBeforeUnload = () => emit('beforeunload');
          window.addEventListener('popstate', onPopState);
          window.addEventListener('hashchange', onHashChange);
          window.addEventListener('pagehide', onPageHide);
          window.addEventListener('beforeunload', onBeforeUnload);

          const originalPushState = history.pushState.bind(history);
          history.pushState = function (...args) {
            const before = location.pathname + location.search + location.hash;
            const result = originalPushState(...args);
            const after = location.pathname + location.search + location.hash;
            routeState = after;
            emit('pushState', { from: before, to: after });
            return result;
          };

          const originalReplaceState = history.replaceState.bind(history);
          history.replaceState = function (...args) {
            const before = location.pathname + location.search + location.hash;
            const result = originalReplaceState(...args);
            const after = location.pathname + location.search + location.hash;
            routeState = after;
            emit('replaceState', { from: before, to: after });
            return result;
          };

          const routePoll = window.setInterval(() => {
            const current = location.pathname + location.search + location.hash;
            if (current !== routeState) {
              emit('route-poll-change', { from: routeState, to: current });
              routeState = current;
            }
          }, 50);

          const observer = new MutationObserver((records) => {
            for (const record of records) {
              if (mutationCount >= 80) return;
              mutationCount += 1;
              emit('mutation', {
                mutation_type: record.type,
                target: summarize(record.target),
                attribute_name: record.attributeName || null,
                added_nodes: record.addedNodes.length,
                removed_nodes: record.removedNodes.length,
              });
            }
          });
          observer.observe(observeRoot, { subtree: true, childList: true, attributes: true });

          window.__satperfActivationCleanup = () => {
            observer.disconnect();
            window.clearInterval(routePoll);
            history.pushState = originalPushState;
            history.replaceState = originalReplaceState;
            window.removeEventListener('popstate', onPopState);
            window.removeEventListener('hashchange', onHashChange);
            window.removeEventListener('pagehide', onPageHide);
            window.removeEventListener('beforeunload', onBeforeUnload);
            for (const type of ['mousedown', 'mouseup', 'click']) {
              document.removeEventListener(type, documentListener, true);
            }
            emit('cleanup');
            delete window.__satperfActivationCleanup;
            return true;
          };

          return {
            enabled: true,
            detail_href: href,
            anchor: summarize(anchor),
            row: summarize(row),
            observe_root: summarize(observeRoot),
          };
        }
        """,
        {"href": detail_href, "prefix": ACTIVATION_DIAGNOSTIC_PREFIX},
    )


def stop_activation_diagnostics(page) -> bool:
    return bool(
        page.evaluate(
            """
            () => {
              if (window.__satperfActivationCleanup) {
                return window.__satperfActivationCleanup();
              }
              return false;
            }
            """
        )
    )


def activate_drilldown_target(page, target, detail_href: str | None, timeout_ms: int) -> str:
    click_timeout = min(timeout_ms, 5000)
    route_wait_timeout = min(timeout_ms, 2000)
    initial_route = current_path(page)
    expected_route = normalize_path(detail_href) if detail_href else None
    last_error = None
    for target_name, activation_target in _activation_targets(page, target, detail_href):
        try:
            activation_target.scroll_into_view_if_needed(timeout=click_timeout)
        except Exception:
            pass

        try:
            activation_target.click(timeout=click_timeout)
            if _wait_for_detail_route(page, expected_route, initial_route, route_wait_timeout):
                return f"{target_name}-click"
        except Exception as exc:
            last_error = exc

        try:
            activation_target.click(timeout=click_timeout, force=True)
            if _wait_for_detail_route(page, expected_route, initial_route, route_wait_timeout):
                return f"{target_name}-force-click"
        except Exception as exc:
            last_error = exc

        if target_name == "href" and detail_href:
            try:
                if _js_click_href(page, detail_href) and _wait_for_detail_route(
                    page, expected_route, initial_route, route_wait_timeout
                ):
                    return f"{target_name}-js-click"
            except Exception as exc:
                last_error = exc

    if last_error is not None:
        raise last_error
    raise RuntimeError("Unable to activate drilldown target")


def discover_menu(page, base_url: str, timeout_ms: int) -> list[dict[str, str]]:
    menu_page = page.context.new_page()
    try:
        menu_page.goto(f"{base_url}/menu", wait_until="domcontentloaded", timeout=timeout_ms)
        raw_body = menu_page.locator("body").inner_text(timeout=timeout_ms)
        menu_entries = json.loads(raw_body)
    finally:
        menu_page.close()

    discovered = []
    seen = set()
    for item in menu_entries:
        url = item.get("url") or ""
        path = normalize_path(url)
        page_id = ROUTE_TO_PAGE_ID.get(path, slugify(item.get("name") or path))
        if page_id in seen:
            continue
        seen.add(page_id)
        discovered.append(
            {
                "id": page_id,
                "name": item.get("name") or page_id,
                "url": path,
            }
        )
    return discovered


def collect_navigation_metrics(page) -> dict[str, float | None]:
    metrics = page.evaluate(
        """
        () => {
          const nav = performance.getEntriesByType('navigation')[0];
          const paints = Object.fromEntries(
            performance.getEntriesByType('paint').map((entry) => [entry.name, entry.startTime])
          );
          const satperf = window.__satperfMetrics || {};

          return {
            total: nav ? nav.duration : null,
            dom_content_loaded: nav ? nav.domContentLoadedEventEnd : null,
            load_event: nav ? nav.loadEventEnd : null,
            first_paint: paints['first-paint'] ?? null,
            first_contentful_paint: paints['first-contentful-paint'] ?? null,
            largest_contentful_paint: satperf.largestContentfulPaint ?? null,
            cls: satperf.cls ?? null,
            long_tasks: satperf.longTasks ? {
              count: satperf.longTasks.count ?? 0,
              total_duration: satperf.longTasks.totalDuration ?? 0,
              total_blocking_time: satperf.longTasks.totalBlockingTime ?? 0,
              max_duration: satperf.longTasks.maxDuration ?? 0,
              samples: satperf.longTasks.samples ?? [],
            } : null,
            phases: nav ? {
              redirect: nav.redirectEnd - nav.redirectStart,
              dns: nav.domainLookupEnd - nav.domainLookupStart,
              tcp: nav.connectEnd - nav.connectStart,
              tls: nav.secureConnectionStart > 0 ? nav.connectEnd - nav.secureConnectionStart : null,
              request_to_first_byte: nav.responseStart - nav.requestStart,
              response_download: nav.responseEnd - nav.responseStart,
              dom_parse: nav.domContentLoadedEventStart - nav.responseEnd,
              dom_content_loaded_handler: nav.domContentLoadedEventEnd - nav.domContentLoadedEventStart,
              load_handler: nav.loadEventEnd - nav.loadEventStart,
              response_to_load: nav.loadEventEnd - nav.responseEnd,
            } : null,
          };
        }
        """
    )
    normalized = {}
    for key, value in metrics.items():
        if key in {"phases", "long_tasks"} and isinstance(value, dict):
            normalized[key] = {
                phase: (
                    [
                        {
                            sample_key: round(sample_value, 2) if isinstance(sample_value, (int, float)) else sample_value
                            for sample_key, sample_value in phase_value.items()
                        }
                        for phase_value in value["samples"]
                    ]
                    if key == "long_tasks" and phase == "samples" and isinstance(phase_value, list)
                    else round(phase_value, 2) if isinstance(phase_value, (int, float)) else phase_value
                )
                for phase, phase_value in value.items()
            }
        else:
            normalized[key] = round(value, 2) if isinstance(value, (int, float)) else value
    phases = normalized.get("phases")
    if isinstance(phases, dict):
        normalized["phases"] = {
            phase: (phase_value if not isinstance(phase_value, (int, float)) or phase_value >= 0 else None)
            for phase, phase_value in phases.items()
        }
    if normalized.get("total") in (None, 0):
        candidates = [
            normalized.get("load_event"),
            normalized.get("dom_content_loaded"),
            normalized.get("largest_contentful_paint"),
            normalized.get("first_contentful_paint"),
            normalized.get("first_paint"),
        ]
        numeric_candidates = [value for value in candidates if isinstance(value, (int, float)) and value > 0]
        normalized["total"] = max(numeric_candidates) if numeric_candidates else None
    return normalized


def visit_route(
    page,
    base_url: str,
    route: str,
    timeout_ms: int,
    ready_text: str | None = None,
    ready_selector: str | None = None,
    request_tracker: RequestTracker | None = None,
) -> dict:
    request_snapshot = request_tracker.snapshot() if request_tracker else 0
    step_started = monotonic()
    page.goto(urljoin(f"{base_url}/", route.lstrip("/")), wait_until="domcontentloaded", timeout=timeout_ms)
    page.wait_for_load_state("networkidle", timeout=timeout_ms)
    readiness = wait_for_dynamic_content(page, timeout_ms, ready_text=ready_text, ready_selector=ready_selector)
    return {
        "effective_route": current_path(page),
        "navigation": collect_navigation_metrics(page),
        "requests": request_tracker.summary_since(request_snapshot) if request_tracker else {},
        "step_duration_ms": round((monotonic() - step_started) * 1000.0, 2),
        "readiness": readiness,
    }


def screenshot_path(artifacts_dir: str | None, browser_name: str, role_name: str, item_id: str) -> str | None:
    if not artifacts_dir:
        return None
    return f"{artifacts_dir}/{browser_name}-{role_name}-{item_id}.png"
