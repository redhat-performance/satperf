# UI Browser Metrics Reference

This document describes the metrics emitted by the Playwright-based UI browser
runner and how to interpret them when tracking performance over time.

It is intended for two use cases:

1. Compare a current run with a historical baseline to spot regressions.
2. Understand what each JSON field actually measures so different timings are
   not compared as if they represented the same window.

## Output shape

The runner writes status JSON with browser, role, page, and workflow results.
The most useful regression-facing sections are:

- `results.browser.browsers.<browser>.roles.<role>.pages.<page_id>`
- `results.browser.browsers.<browser>.roles.<role>.workflows.<workflow_id>`

The most important metric groups are:

- `navigation`
- `requests`
- `steps`
- `readiness`
- `list_state` for skipped workflows

## What to compare first

These are the most useful fields to baseline first:

- `navigation.total`
- `navigation.largest_contentful_paint`
- `navigation.long_tasks.total_blocking_time`
- `navigation.long_tasks.max_duration`
- `requests.total`
- `requests.sequencing.last_request_end_offset_ms`
- `requests.sequencing.max_concurrent`
- `steps.shell_ready_ms`
- `steps.content_ready_ms`
- `steps.page_ready_ms`
- `workflow.steps.list_ready_ms`
- `workflow.steps.detail_ready_ms`
- `workflow.steps.total_workflow_ms`

## Quick interpretation guide

Use these patterns when comparing runs:

- `navigation.total` flat, `steps.content_ready_ms` worse:
  post-navigation rendering or data readiness likely regressed.
- `navigation.long_tasks.total_blocking_time` worse:
  more main-thread blocking, often from frontend JavaScript work.
- `requests.sequencing.last_request_end_offset_ms` worse:
  longer network tail after the step begins.
- `requests.sequencing.max_concurrent` worse:
  higher request fan-out or burstiness.
- `workflow.steps.list_ready_ms` flat, `workflow.steps.detail_ready_ms` worse:
  the regression is likely in the detail page, not the list page.

## Exact measurement windows

This section describes the exact start and stop window for the key fields.

### Browser navigation metrics

Collected by `collect_navigation_metrics()` in
`playbooks/tests/files/ui-browser/navigation.py`.

#### `navigation.total`

- Start: browser navigation start
- Stop: browser navigation entry `duration`
- Source: `performance.getEntriesByType('navigation')[0].duration`
- Best used for: raw browser navigation cost

#### `navigation.dom_content_loaded`

- Start: browser navigation start
- Stop: `domContentLoadedEventEnd`
- Source: navigation timing entry
- Best used for: DOM-ready timing

#### `navigation.load_event`

- Start: browser navigation start
- Stop: `loadEventEnd`
- Source: navigation timing entry
- Best used for: load-event completion timing

#### `navigation.first_paint`

- Start: browser navigation start
- Stop: first paint timestamp
- Source: paint timing entries
- Best used for: first visible render

#### `navigation.first_contentful_paint`

- Start: browser navigation start
- Stop: first contentful paint timestamp
- Source: paint timing entries
- Best used for: initial visible content timing

#### `navigation.largest_contentful_paint`

- Start: page lifetime after metric observer injection
- Stop: last buffered LCP entry seen before metric collection
- Source: `window.__satperfMetrics` populated by `inject_metric_observers()`
- Best used for: perceived main content rendering

#### `navigation.cls`

- Start: page lifetime after metric observer injection
- Stop: metric collection time
- Source: layout shift observer in `inject_metric_observers()`
- Best used for: cumulative layout instability

#### `navigation.long_tasks.count`

- Start: page lifetime after metric observer injection
- Stop: metric collection time
- Source: long-task observer in `inject_metric_observers()`
- Best used for: number of >50ms main-thread tasks

#### `navigation.long_tasks.total_duration`

- Start: page lifetime after metric observer injection
- Stop: metric collection time
- Source: long-task observer
- Best used for: total long-task wall time

#### `navigation.long_tasks.total_blocking_time`

- Start: page lifetime after metric observer injection
- Stop: metric collection time
- Source: sum of `duration - 50ms` across long-task entries
- Best used for: main-thread blocking regression signal

#### `navigation.long_tasks.max_duration`

- Start: page lifetime after metric observer injection
- Stop: metric collection time
- Source: longest observed long-task entry
- Best used for: worst single UI freeze

#### `navigation.phases.request_to_first_byte`

- Start: request start for the navigation document
- Stop: response start for that document
- Source: navigation timing entry arithmetic
- Best used for: backend/server response delay

#### `navigation.phases.response_download`

- Start: first response byte for the navigation document
- Stop: response end
- Source: navigation timing entry arithmetic
- Best used for: document transfer time

#### `navigation.phases.dom_parse`

- Start: response end
- Stop: DOMContentLoaded handler start
- Source: navigation timing entry arithmetic
- Best used for: parse and setup work after the document arrives

#### `navigation.phases.response_to_load`

- Start: response end
- Stop: load event end
- Source: navigation timing entry arithmetic
- Best used for: client-side work after the document finishes downloading

### Request metrics

Collected by `RequestTracker` in
`playbooks/tests/files/ui-browser/navigation.py`.

The request window starts at `RequestTracker.snapshot()` and ends when
`summary_since(snapshot)` is called.

#### `requests.total`

- Start: first request after the snapshot point
- Stop: summary collection time
- Source: finished or failed requests in the snapshot window
- Best used for: total request fan-out for the step

#### `requests.api_requests`

- Start: snapshot baseline
- Stop: summary collection time
- Source: requests with resource type `fetch` or `xhr`
- Best used for: API chatter growth

#### `requests.document_requests`

- Start: snapshot baseline
- Stop: summary collection time
- Source: requests with resource type `document`
- Best used for: document navigation count

#### `requests.by_resource_type`

- Start: snapshot baseline
- Stop: summary collection time
- Source: request records grouped by resource type
- Best used for: request mix changes

#### `requests.top_slowest`

- Start: snapshot baseline
- Stop: summary collection time
- Source: slowest finished requests in the window
- Best used for: identifying dominant slow requests

#### `requests.failed_samples`

- Start: snapshot baseline
- Stop: summary collection time
- Source: failed requests in the window
- Best used for: request-failure context during regressions

#### `requests.sequencing.first_request_offset_ms`

- Start: snapshot baseline
- Stop: first request start after the snapshot
- Source: relative offsets from `RequestTracker.snapshot()`
- Best used for: how soon network activity begins

#### `requests.sequencing.last_request_end_offset_ms`

- Start: snapshot baseline
- Stop: latest request end in the window
- Source: relative offsets from `RequestTracker.snapshot()`
- Best used for: long request tail detection

#### `requests.sequencing.max_concurrent`

- Start: earliest request start in the snapshot window
- Stop: latest request end in the snapshot window
- Source: overlap across recorded request intervals
- Best used for: burstiness and request fan-out

#### `requests.sequencing.peak_concurrent_at_ms`

- Start: snapshot baseline
- Stop: point where overlap reached its maximum
- Source: request interval overlap calculation
- Best used for: when peak request pressure occurs

#### `requests.sequencing.span_ms`

- Start: earliest request start in the snapshot window
- Stop: latest request end in the snapshot window
- Source: request interval spread
- Best used for: total request burst length

#### `requests.sequencing.timeline`

- Start: snapshot baseline
- Stop: summary collection time
- Source: ordered request samples with relative offsets
- Best used for: understanding request ordering patterns

### Readiness metrics

Collected by `wait_for_dynamic_content()` in
`playbooks/tests/files/ui-browser/navigation.py`.

#### `readiness.shell_ready_ms`

- Start: beginning of `wait_for_dynamic_content()`
- Stop: `wait_for_page_ready()` success
- Source: monotonic stopwatch
- Best used for: initial shell availability

#### `readiness.content_ready_ms`

- Start: beginning of `wait_for_dynamic_content()`
- Stop: when the page content signature remains stable for
  `CONTENT_SETTLE_MS`
- Source: monotonic stopwatch
- Best used for: practical page usability

#### `readiness.readiness_mode`

- Timing window: not a duration
- Source: DOM shape classification in `inspect_content_state()`
- Best used for: understanding which readiness heuristic fired

#### `readiness.readiness_signals`

- Timing window: snapshot at readiness completion
- Source: DOM visibility and content summary
- Best used for: debugging why a page was considered ready

### Page step timings

Collected by `visit_route()` and stored by `evaluate_role()` in
`playbooks/tests/files/ui-browser/runner.py`.

#### `steps.page_ready_ms`

- Start: right before `page.goto()` in `visit_route()`
- Stop: after `networkidle` and dynamic-content readiness complete
- Source: monotonic stopwatch
- Best used for: end-to-end page step duration

#### `steps.shell_ready_ms`

- Start: same page step start
- Stop: shell readiness success
- Source: `wait_for_dynamic_content()`
- Best used for: shell arrival timing

#### `steps.content_ready_ms`

- Start: same page step start
- Stop: dynamic-content stability
- Source: `wait_for_dynamic_content()`
- Best used for: content stability timing

### Workflow timings

Collected in `evaluate_role()` in
`playbooks/tests/files/ui-browser/runner.py`.

#### `workflow.duration`

- Start: right before interaction or drilldown activation begins
- Stop: after detail or interaction readiness completes
- Source: monotonic stopwatch
- Best used for: interaction/drilldown phase duration

#### `workflow.steps.list_ready_ms`

- Start: list page `visit_route()` start
- Stop: list page readiness completion
- Source: list step duration
- Best used for: list page regressions

#### `workflow.steps.detail_ready_ms`

- Start: right before drilldown activation
- Stop: after route transition, `networkidle`, and detail readiness
- Source: monotonic stopwatch
- Best used for: detail page regressions

#### `workflow.steps.interaction_ready_ms`

- Start: right before search interaction begins
- Stop: after interaction stabilization and readiness
- Source: monotonic stopwatch
- Best used for: search/filter interaction regressions

#### `workflow.steps.total_workflow_ms`

- Start: derived value
- Stop: derived value
- Source: `list_ready_ms + detail_ready_ms` or
  `list_ready_ms + interaction_ready_ms`
- Best used for: coarse workflow trend tracking

#### `workflow.steps.list_page.requests`

- Start: request snapshot taken before list-page visit
- Stop: summary collection after list-page readiness
- Source: `RequestTracker.summary_since()`
- Best used for: list page request behavior

#### `workflow.steps.detail_page.requests`

- Start: request snapshot taken before drilldown activation
- Stop: summary collection after detail-page readiness
- Source: `RequestTracker.summary_since()`
- Best used for: detail page request behavior

### Skip classification

Collected by `classify_list_state()` in
`playbooks/tests/files/ui-browser/navigation.py`.

#### `list_state.classification`

- Timing window: snapshot taken when no drilldown target is found or when a
  workflow-selection error falls back to classification
- Source: DOM state and text inspection
- Best used for: distinguishing empty states from actionable but problematic
  pages

## Recommended first regression contract

If you want to keep the first regression contract small, start with:

- `dashboard`
- `hosts`
- `job_invocations`
- `tasks`
- `content_views`
- `hosts_list_to_details`
- `job_invocations_list_to_details`
- `repositories_list_to_details`

For those, compare:

- `navigation.total`
- `navigation.largest_contentful_paint`
- `navigation.long_tasks.total_blocking_time`
- `requests.sequencing.last_request_end_offset_ms`
- `steps.content_ready_ms`
- workflow `total_workflow_ms`

Prefer medians from repeated runs over a single sample before defining hard
thresholds.

## Historical regression contract

The runner also emits a flattened historical comparison contract under
`results.browser.contract` for the fixed Chromium/Firefox page and workflow
subset used by Investigator.

### Aggregate lanes

Per `browser -> role`, `results.browser.contract.lanes` includes:

- required page/workflow pass, fail, and skipped counts
- `fail_ratio`
- `console_errors`
- `network_errors`
- page medians for:
  - `navigation_total_ms`
  - `largest_contentful_paint_ms`
  - `total_blocking_time_ms`
  - `last_request_end_offset_ms`
- workflow medians for:
  - `content_ready_ms`
  - `total_workflow_ms`

### Fixed item set

Per `browser -> role`, `results.browser.contract.items` includes item-level
metrics for these tracked pages:

- `dashboard`
- `hosts`
- `job_invocations`
- `tasks`
- `content_views`

and these tracked workflows:

- `hosts_list_to_details`
- `job_invocations_list_to_details`
- `repositories_list_to_details`

Each item includes a human-readable `status`, numeric `status_ok`, and the
main scalar timing fields used for release-over-release comparison.
