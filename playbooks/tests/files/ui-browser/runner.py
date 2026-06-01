#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
import traceback
from dataclasses import dataclass
from pathlib import Path
from time import monotonic
from typing import Any

from auth import inject_metric_observers, login
from navigation import (
    activate_drilldown_target,
    RequestTracker,
    collect_navigation_metrics,
    classify_list_state,
    current_path,
    discover_menu,
    find_drilldown_target,
    perform_search_interaction,
    screenshot_path,
    visit_route,
    wait_for_dynamic_content,
)
from output import compact, pct_delta, platform_metadata, utc_now
from scenarios import PAGE_SCENARIOS, WORKFLOW_SCENARIOS, page_ids_for_role

HOST_PAGE_IDS = ("hosts", "hosts_new")


@dataclass(frozen=True)
class RoleConfig:
    name: str
    username: str
    password: str
    required_pages: list[str]


def parse_csv(raw: str | None) -> list[str]:
    if not raw:
        return []
    return [item.strip() for item in raw.split(",") if item.strip()]


def verbose_log(args: argparse.Namespace, message: str) -> None:
    progress_log_file = getattr(args, "progress_log_file", "")
    if progress_log_file:
        progress_path = Path(progress_log_file)
        progress_path.parent.mkdir(parents=True, exist_ok=True)
        with progress_path.open("a", encoding="utf-8") as handle:
            handle.write(f"{utc_now()} {message}\n")
    if getattr(args, "verbose", False):
        print(message, flush=True)


def capture_failure_screenshot(
    page: Any,
    args: argparse.Namespace,
    browser_name: str,
    role_name: str,
    item_id: str,
) -> str | None:
    if not args.capture_screenshot_on_failure:
        return None
    image_path = screenshot_path(args.artifacts_dir or None, browser_name, role_name, item_id)
    if not image_path:
        return None
    try:
        Path(image_path).parent.mkdir(parents=True, exist_ok=True)
        page.screenshot(path=image_path, full_page=True, timeout=min(args.timeout_seconds * 1000, 10000))
        return None
    except Exception as exc:  # pragma: no cover - depends on live UI
        return str(exc)


def discovered_host_page_id(discovered_menu: list[dict[str, str]]) -> str | None:
    for entry in discovered_menu:
        if entry["id"] in HOST_PAGE_IDS:
            return entry["id"]
    return None


def required_page_missing(required_page_id: str, visited_pages: set[str]) -> bool:
    if required_page_id == "hosts":
        return not any(page_id in visited_pages for page_id in HOST_PAGE_IDS)
    return required_page_id not in visited_pages


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Run satperf UI browser performance checks with Playwright.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--status-data-file", required=True)
    parser.add_argument("--dataset-profile", default="medium")
    parser.add_argument("--browsers", default="chromium,firefox")
    parser.add_argument("--browser-source", default="playwright-bundled", choices=["playwright-bundled"])
    parser.add_argument("--roles", default="admin,viewer")
    parser.add_argument("--admin-username", default="admin")
    parser.add_argument("--admin-password", default="changeme")
    parser.add_argument("--viewer-username", default="ui-perf-viewer")
    parser.add_argument("--viewer-password", default="changeme")
    parser.add_argument("--required-pages-admin", default="dashboard,hosts,job_invocations,content_views,tasks")
    parser.add_argument("--required-pages-viewer", default="dashboard,hosts,job_invocations,tasks")
    parser.add_argument(
        "--workflows",
        default="login_to_dashboard,hosts_list_to_details,job_invocations_list_to_details",
    )
    parser.add_argument("--visit-all-left-nav", action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument("--skip-pages", default="")
    parser.add_argument("--headless", action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument("--timeout-seconds", type=int, default=60)
    parser.add_argument("--iterations", type=int, default=1)
    parser.add_argument("--verbose", action=argparse.BooleanOptionalAction, default=False)
    parser.add_argument("--progress-log-file", default="")
    parser.add_argument("--capture-trace", action=argparse.BooleanOptionalAction, default=False)
    parser.add_argument("--capture-screenshot-on-failure", action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument("--artifacts-dir", default="")
    return parser


def build_role_configs(args: argparse.Namespace) -> list[RoleConfig]:
    requested_roles = parse_csv(args.roles)
    configs = []
    if "admin" in requested_roles:
        configs.append(
            RoleConfig(
                name="admin",
                username=args.admin_username,
                password=args.admin_password,
                required_pages=parse_csv(args.required_pages_admin),
            )
        )
    if "viewer" in requested_roles:
        configs.append(
            RoleConfig(
                name="viewer",
                username=args.viewer_username,
                password=args.viewer_password,
                required_pages=parse_csv(args.required_pages_viewer),
            )
        )
    return configs


def launch_browser(playwright: Any, browser_name: str, args: argparse.Namespace):
    browser_type = getattr(playwright, browser_name)
    launch_kwargs: dict[str, Any] = {"headless": args.headless}
    return browser_type.launch(**launch_kwargs)


def make_context(browser, args: argparse.Namespace):
    context = browser.new_context(ignore_https_errors=True)
    inject_metric_observers(context)
    if args.capture_trace:
        context.tracing.start(screenshots=True, snapshots=True, sources=False)
    return context


def role_error_delta(before: dict[str, int], after: dict[str, int]) -> dict[str, int]:
    return {
        "console": max(0, after["console"] - before["console"]),
        "network": max(0, after["network"] - before["network"]),
    }


def evaluate_role(
    browser_name: str,
    context: Any,
    role: RoleConfig,
    args: argparse.Namespace,
) -> dict[str, Any]:
    page = context.new_page()
    request_tracker = RequestTracker(page)
    timeout_ms = args.timeout_seconds * 1000
    counts = {"console": 0, "network": 0}
    skip_page_ids = set(parse_csv(args.skip_pages))
    verbose_log(args, f"[{browser_name}][{role.name}] login start")

    def on_console(message):
        if message.type == "error":
            counts["console"] += 1

    def on_request_failed(_request):
        counts["network"] += 1

    page.on("console", on_console)
    page.on("requestfailed", on_request_failed)

    role_result: dict[str, Any] = {
        "coverage": {
            "discovered": [],
            "visited": [],
            "skipped": [],
            "failed": [],
        },
        "pages": {},
        "workflows": {},
        "vitals": {},
        "errors": {"console": 0, "network": 0},
        "status": "PASS",
    }

    try:
        login_started = utc_now()
        login_clock_started = monotonic()
        login_request_snapshot = request_tracker.snapshot()
        login(page, args.base_url, role.username, role.password, timeout_ms)
        login_ended = utc_now()
        role_result["workflows"]["login_to_dashboard"] = {
            "duration": round((monotonic() - login_clock_started) * 1000.0, 2),
            "status": "PASS",
            "started": login_started,
            "ended": login_ended,
            "navigation": collect_navigation_metrics(page),
            "requests": request_tracker.summary_since(login_request_snapshot),
            "steps": {
                "login_ready_ms": round((monotonic() - login_clock_started) * 1000.0, 2),
            },
        }
        verbose_log(
            args,
            f"[{browser_name}][{role.name}] login pass {role_result['workflows']['login_to_dashboard']['duration']}ms",
        )

        discovered_menu = discover_menu(page, args.base_url, timeout_ms) if args.visit_all_left_nav else []
        role_result["coverage"]["discovered"] = [entry["id"] for entry in discovered_menu]
        discovered_route_by_page_id = {entry["id"]: entry["url"] for entry in discovered_menu}
        menu_host_page_id = discovered_host_page_id(discovered_menu)
        if args.visit_all_left_nav:
            verbose_log(
                args,
                f"[{browser_name}][{role.name}] discovered {len(discovered_menu)} menu entries",
            )

        required_pages = compact(role.required_pages)
        if args.visit_all_left_nav:
            for entry in discovered_menu:
                page_id = entry["id"]
                if page_id in skip_page_ids:
                    role_result["coverage"]["skipped"].append(page_id)
                    verbose_log(args, f"[{browser_name}][{role.name}] page {page_id} skipped by configuration")
                    continue
                before_counts = counts.copy()
                try:
                    verbose_log(args, f"[{browser_name}][{role.name}] page {page_id} start {entry['url']}")
                    visit = visit_route(page, args.base_url, entry["url"], timeout_ms, request_tracker=request_tracker)
                    role_result["coverage"]["visited"].append(page_id)
                    if page_id not in role_result["pages"]:
                        role_result["pages"][page_id] = {
                            "route": entry["url"],
                            "effective_route": visit["effective_route"],
                            "navigation": visit["navigation"],
                            "requests": visit["requests"],
                            "steps": {
                                "page_ready_ms": visit["step_duration_ms"],
                                "shell_ready_ms": visit["readiness"]["shell_ready_ms"],
                                "content_ready_ms": visit["readiness"]["content_ready_ms"],
                            },
                            "readiness": visit["readiness"],
                            "errors": role_error_delta(before_counts, counts),
                        }
                    verbose_log(
                        args,
                        f"[{browser_name}][{role.name}] page {page_id} pass total={visit['navigation'].get('total')}",
                    )
                except Exception as exc:  # pragma: no cover - depends on live UI
                    role_result["coverage"]["failed"].append(page_id)
                    role_result["pages"].setdefault(page_id, {})
                    role_result["pages"][page_id]["error"] = str(exc)
                    verbose_log(args, f"[{browser_name}][{role.name}] page {page_id} fail {exc}")
                    screenshot_error = capture_failure_screenshot(page, args, browser_name, role.name, page_id)
                    if screenshot_error:
                        role_result["pages"][page_id]["screenshot_error"] = screenshot_error
                        verbose_log(args, f"[{browser_name}][{role.name}] page {page_id} screenshot failed {screenshot_error}")

        for page_id in page_ids_for_role(role.name):
            if page_id in skip_page_ids:
                verbose_log(args, f"[{browser_name}][{role.name}] scenario {page_id} skipped by configuration")
                continue
            if page_id in HOST_PAGE_IDS and page_id == menu_host_page_id:
                verbose_log(
                    args,
                    f"[{browser_name}][{role.name}] scenario {page_id} skipped because /menu already covered the primary hosts route",
                )
                continue
            scenario = PAGE_SCENARIOS[page_id]
            before_counts = counts.copy()
            scenario_route = scenario.route
            scenario_required = scenario.required_by_default
            scenario_mode = scenario.variant
            if page_id in HOST_PAGE_IDS and menu_host_page_id:
                scenario_required = False
                scenario_mode = f"{scenario.variant}/tentative"
            list_step = None
            try:
                verbose_log(
                    args,
                    f"[{browser_name}][{role.name}] scenario {page_id} start {scenario_route} ({scenario_mode})",
                )
                visit = visit_route(
                    page,
                    args.base_url,
                    scenario_route,
                    timeout_ms,
                    ready_text=scenario.ready_text,
                    ready_selector=scenario.ready_selector,
                    request_tracker=request_tracker,
                )
                role_result["pages"][page_id] = {
                    "route": scenario_route,
                    "effective_route": visit["effective_route"],
                    "variant": scenario_mode,
                    "navigation": visit["navigation"],
                    "requests": visit["requests"],
                    "steps": {
                        "page_ready_ms": visit["step_duration_ms"],
                        "shell_ready_ms": visit["readiness"]["shell_ready_ms"],
                        "content_ready_ms": visit["readiness"]["content_ready_ms"],
                    },
                    "readiness": visit["readiness"],
                    "errors": role_error_delta(before_counts, counts),
                }
                if visit["navigation"].get("largest_contentful_paint") is not None:
                    role_result["vitals"][f"{page_id}.largest_contentful_paint"] = visit["navigation"]["largest_contentful_paint"]
                if page_id not in role_result["coverage"]["visited"]:
                    role_result["coverage"]["visited"].append(page_id)
                verbose_log(
                    args,
                    f"[{browser_name}][{role.name}] scenario {page_id} pass total={visit['navigation'].get('total')}",
                )
            except Exception as exc:  # pragma: no cover - depends on live UI
                role_result["pages"].setdefault(page_id, {})
                role_result["pages"][page_id]["error"] = str(exc)
                role_result["pages"][page_id]["route"] = scenario_route
                role_result["pages"][page_id]["variant"] = scenario_mode
                if page_id in required_pages or scenario_required:
                    role_result["coverage"]["failed"].append(page_id)
                elif page_id not in role_result["coverage"]["skipped"]:
                    role_result["coverage"]["skipped"].append(page_id)
                verbose_log(args, f"[{browser_name}][{role.name}] scenario {page_id} fail {exc}")
                screenshot_error = capture_failure_screenshot(page, args, browser_name, role.name, page_id)
                if screenshot_error:
                    role_result["pages"][page_id]["screenshot_error"] = screenshot_error
                    verbose_log(args, f"[{browser_name}][{role.name}] scenario {page_id} screenshot failed {screenshot_error}")

        requested_workflows = parse_csv(args.workflows)
        for workflow_id in requested_workflows:
            workflow = WORKFLOW_SCENARIOS.get(workflow_id)
            if not workflow or role.name not in workflow.roles:
                continue
            if workflow_id == "login_to_dashboard":
                continue

            before_counts = counts.copy()
            list_step = None
            workflow_result = {"status": "SKIPPED"}
            workflow_route = workflow.list_route or "/"
            workflow_required = workflow.required
            workflow_mode = workflow.variant
            workflow_menu_page_id = workflow.menu_page_id
            if workflow_menu_page_id in HOST_PAGE_IDS and menu_host_page_id:
                if workflow_menu_page_id == menu_host_page_id:
                    workflow_route = discovered_route_by_page_id.get(menu_host_page_id, workflow_route)
                    workflow_required = True
                    workflow_mode = f"{workflow.variant}/menu"
                else:
                    workflow_required = False
                    workflow_mode = f"{workflow.variant}/tentative"
            elif args.visit_all_left_nav and workflow_menu_page_id:
                discovered_workflow_route = discovered_route_by_page_id.get(workflow_menu_page_id)
                if discovered_workflow_route:
                    workflow_route = discovered_workflow_route
                    workflow_mode = f"{workflow.variant}/menu"
                else:
                    workflow_result = {
                        "status": "SKIPPED",
                        "reason": f"Menu route not discovered for {workflow_menu_page_id}",
                        "list_route": workflow_route,
                        "variant": workflow_mode,
                    }
                    verbose_log(
                        args,
                        f"[{browser_name}][{role.name}] workflow {workflow_id} skipped menu route missing for {workflow_menu_page_id}",
                    )
                    role_result["workflows"][workflow_id] = workflow_result
                    continue
            try:
                verbose_log(
                    args,
                    f"[{browser_name}][{role.name}] workflow {workflow_id} start {workflow_route} ({workflow_mode})",
                )
                list_step = visit_route(
                    page,
                    args.base_url,
                    workflow_route,
                    timeout_ms,
                    ready_text=workflow.ready_text,
                    ready_selector=workflow.ready_selector,
                    request_tracker=request_tracker,
                )
                if workflow.workflow_kind == "search":
                    started = utc_now()
                    duration_started = monotonic()
                    detail_request_snapshot = request_tracker.snapshot()
                    interaction = perform_search_interaction(page, workflow.search_term or "", timeout_ms)
                    detail_readiness = wait_for_dynamic_content(page, timeout_ms)
                    ended = utc_now()
                    detail_duration = round((monotonic() - duration_started) * 1000.0, 2)
                    workflow_result = {
                        "duration": detail_duration,
                        "status": "PASS",
                        "started": started,
                        "ended": ended,
                        "effective_route": current_path(page),
                        "list_route": workflow_route,
                        "variant": workflow_mode,
                        "interaction_mode": interaction["interaction_mode"],
                        "interaction_target": interaction["search_term"],
                        "errors": role_error_delta(before_counts, counts),
                        "steps": {
                            "list_ready_ms": list_step["step_duration_ms"],
                            "interaction_ready_ms": detail_duration,
                            "total_workflow_ms": round(list_step["step_duration_ms"] + detail_duration, 2),
                            "list_page": {
                                "effective_route": list_step["effective_route"],
                                "navigation": list_step["navigation"],
                                "requests": list_step["requests"],
                                "readiness": list_step["readiness"],
                            },
                            "interaction_page": {
                                "effective_route": current_path(page),
                                "navigation": collect_navigation_metrics(page),
                                "requests": request_tracker.summary_since(detail_request_snapshot),
                                "readiness": detail_readiness,
                                "before": interaction["before"],
                                "after": interaction["after"],
                            },
                        },
                    }
                    verbose_log(
                        args,
                        f"[{browser_name}][{role.name}] workflow {workflow_id} pass {workflow_result['duration']}ms",
                    )
                else:
                    link, detail_href, drilldown_mode = find_drilldown_target(
                        page,
                        workflow.detail_href_contains,
                        workflow.disallowed_detail_href_contains,
                        timeout_ms=min(timeout_ms, 5000),
                    )
                    if link is None:
                        list_state = classify_list_state(page, route=workflow_route)
                        workflow_result = {
                            "status": "SKIPPED",
                            "reason": f"No matching drilldown target found ({list_state['classification']})",
                            "list_state": list_state,
                            "list_route": workflow_route,
                            "variant": workflow_mode,
                            "steps": {
                                "list_page": {
                                    "effective_route": list_step["effective_route"],
                                    "navigation": list_step["navigation"],
                                    "requests": list_step["requests"],
                                    "readiness": list_step["readiness"],
                                }
                            },
                        }
                        verbose_log(
                            args,
                            f"[{browser_name}][{role.name}] workflow {workflow_id} skipped no matching drilldown target ({list_state['classification']})",
                        )
                    else:
                        started = utc_now()
                        duration_started = monotonic()
                        detail_request_snapshot = request_tracker.snapshot()
                        drilldown_activation_mode = activate_drilldown_target(page, link, detail_href, timeout_ms)
                        page.wait_for_load_state("networkidle", timeout=timeout_ms)
                        detail_readiness = wait_for_dynamic_content(page, timeout_ms)
                        ended = utc_now()
                        detail_duration = round((monotonic() - duration_started) * 1000.0, 2)
                        workflow_result = {
                            "duration": detail_duration,
                            "status": "PASS",
                            "started": started,
                            "ended": ended,
                            "detail_href": detail_href,
                            "effective_route": current_path(page),
                            "list_route": workflow_route,
                            "variant": workflow_mode,
                            "drilldown_mode": drilldown_mode,
                            "drilldown_activation_mode": drilldown_activation_mode,
                            "errors": role_error_delta(before_counts, counts),
                            "steps": {
                                "list_ready_ms": list_step["step_duration_ms"],
                                "detail_ready_ms": detail_duration,
                                "total_workflow_ms": round(list_step["step_duration_ms"] + detail_duration, 2),
                                "list_page": {
                                    "effective_route": list_step["effective_route"],
                                    "navigation": list_step["navigation"],
                                    "requests": list_step["requests"],
                                    "readiness": list_step["readiness"],
                                },
                                "detail_page": {
                                    "effective_route": current_path(page),
                                    "navigation": collect_navigation_metrics(page),
                                    "requests": request_tracker.summary_since(detail_request_snapshot),
                                    "readiness": detail_readiness,
                                },
                            },
                        }
                        verbose_log(
                            args,
                            f"[{browser_name}][{role.name}] workflow {workflow_id} pass {workflow_result['duration']}ms",
                        )
            except Exception as exc:  # pragma: no cover - depends on live UI
                workflow_result = {
                    "status": "FAIL" if workflow_required else "SKIPPED",
                    "error": str(exc),
                    "list_route": workflow_route,
                    "effective_route": current_path(page),
                    "variant": workflow_mode,
                    "steps": {
                        "list_page": list_step,
                    },
                }
                if workflow_result["status"] == "SKIPPED" and list_step is not None:
                    list_state = classify_list_state(page, route=workflow_route)
                    workflow_result["list_state"] = list_state
                    workflow_result["reason"] = f"Workflow selection error ({list_state['classification']})"
                verbose_log(
                    args,
                    f"[{browser_name}][{role.name}] workflow {workflow_id} {workflow_result['status'].lower()} {exc}",
                )
                screenshot_error = capture_failure_screenshot(page, args, browser_name, role.name, workflow_id)
                if screenshot_error:
                    workflow_result["screenshot_error"] = screenshot_error
                    verbose_log(
                        args,
                        f"[{browser_name}][{role.name}] workflow {workflow_id} screenshot failed {screenshot_error}",
                    )
            role_result["workflows"][workflow_id] = workflow_result

        role_result["coverage"]["discovered"] = sorted(set(role_result["coverage"]["discovered"]))
        role_result["coverage"]["visited"] = sorted(set(role_result["coverage"]["visited"]))
        role_result["coverage"]["skipped"] = sorted(set(role_result["coverage"]["skipped"]))
        role_result["coverage"]["failed"] = sorted(set(role_result["coverage"]["failed"]))
        role_result["coverage"]["discovered_count"] = len(role_result["coverage"]["discovered"])
        role_result["coverage"]["visited_count"] = len(role_result["coverage"]["visited"])
        role_result["coverage"]["skipped_count"] = len(role_result["coverage"]["skipped"])
        role_result["coverage"]["failed_count"] = len(role_result["coverage"]["failed"])

        visited_pages = set(role_result["coverage"]["visited"])
        missing_required = sorted(
            required_page_id
            for required_page_id in set(required_pages)
            if required_page_missing(required_page_id, visited_pages)
        )
        if missing_required:
            role_result["coverage"]["missing_required"] = missing_required
            role_result["status"] = "FAIL"

        if role_result["coverage"]["failed_count"] > 0:
            role_result["status"] = "FAIL"
        if any(item.get("status") == "FAIL" for item in role_result["workflows"].values()):
            role_result["status"] = "FAIL"

        role_result["errors"] = counts
        verbose_log(
            args,
            f"[{browser_name}][{role.name}] role complete status={role_result['status']} visited={role_result['coverage']['visited_count']} failed={role_result['coverage']['failed_count']}",
        )
    finally:
        page.close()

    return role_result


def build_browser_comparison(browser_result: dict[str, Any]) -> dict[str, Any]:
    admin = browser_result["roles"].get("admin", {})
    viewer = browser_result["roles"].get("viewer", {})
    comparison = {
        "coverage": {
            "only_in_admin": sorted(set(admin.get("coverage", {}).get("visited", [])) - set(viewer.get("coverage", {}).get("visited", []))),
            "only_in_viewer": sorted(set(viewer.get("coverage", {}).get("visited", [])) - set(admin.get("coverage", {}).get("visited", []))),
        },
        "pages": {},
        "workflows": {},
    }

    for page_id in sorted(set(admin.get("pages", {})) & set(viewer.get("pages", {}))):
        admin_total = admin["pages"][page_id].get("navigation", {}).get("total")
        viewer_total = viewer["pages"][page_id].get("navigation", {}).get("total")
        delta = pct_delta(admin_total, viewer_total)
        if delta is not None:
            comparison["pages"][page_id] = {"navigation_delta_pct": {"total": delta}}

    for workflow_id in sorted(set(admin.get("workflows", {})) & set(viewer.get("workflows", {}))):
        admin_duration = admin["workflows"][workflow_id].get("duration")
        viewer_duration = viewer["workflows"][workflow_id].get("duration")
        delta = pct_delta(admin_duration, viewer_duration)
        if delta is not None:
            comparison["workflows"][workflow_id] = {"duration_delta_pct": delta}

    return comparison


def run(args: argparse.Namespace) -> dict[str, Any]:
    started = utc_now()
    result = {
        "id": f"ui-browser-{started}",
        "name": "UIBrowserNavigation",
        "result": "PASS",
        "started": started,
        "ended": None,
        "parameters": {
            "roles": parse_csv(args.roles),
            "dataset_profile": args.dataset_profile,
            "platform": platform_metadata(),
            "browser": {
                "names": parse_csv(args.browsers),
                "source": args.browser_source,
            },
        },
        "results": {
            "browser": {
                "browsers": {},
            }
        },
    }

    browsers = parse_csv(args.browsers)
    roles = build_role_configs(args)
    fatal_error = None

    try:
        from playwright.sync_api import sync_playwright  # type: ignore

        Path(args.artifacts_dir).mkdir(parents=True, exist_ok=True) if args.artifacts_dir else None

        with sync_playwright() as playwright:
            for browser_name in browsers:
                verbose_log(args, f"[runner] browser {browser_name} start")
                browser_result: dict[str, Any] = {"roles": {}, "comparison": {}}
                browser = launch_browser(playwright, browser_name, args)
                try:
                    for role in roles:
                        context = make_context(browser, args)
                        try:
                            role_result = evaluate_role(browser_name, context, role, args)
                            browser_result["roles"][role.name] = role_result
                            if role_result["status"] != "PASS":
                                result["result"] = "FAIL"
                        finally:
                            if args.capture_trace:
                                trace_path = Path(args.artifacts_dir or ".") / f"trace-{browser_name}-{role.name}.zip"
                                context.tracing.stop(path=str(trace_path))
                            context.close()
                    browser_result["comparison"] = build_browser_comparison(browser_result)
                    browser_status = "PASS"
                    if any(role_data.get("status") != "PASS" for role_data in browser_result["roles"].values()):
                        browser_status = "FAIL"
                    verbose_log(args, f"[runner] browser {browser_name} complete status={browser_status}")
                finally:
                    browser.close()
                result["results"]["browser"]["browsers"][browser_name] = browser_result
    except Exception as exc:  # pragma: no cover - failure path
        fatal_error = exc
        result["result"] = "ERROR"
        result["results"]["browser"]["fatal_error"] = str(exc)
        result["results"]["browser"]["traceback"] = traceback.format_exc()
        verbose_log(args, f"[runner] fatal error {exc}")

    result["ended"] = utc_now()
    if fatal_error is not None:
        result["results"]["browser"]["completed"] = False
    else:
        result["results"]["browser"]["completed"] = True
    return result


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    result = run(args)

    status_data_path = Path(args.status_data_file)
    status_data_path.parent.mkdir(parents=True, exist_ok=True)
    status_data_path.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    browsers = "_".join(parse_csv(args.browsers))
    roles = "_".join(parse_csv(args.roles))
    print(f"UIBrowserNavigation_browsers_{browsers}_roles_{roles} wrote {status_data_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
