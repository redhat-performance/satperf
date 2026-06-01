from __future__ import annotations

from dataclasses import dataclass
from typing import Dict, List, Optional


@dataclass(frozen=True)
class PageScenario:
    id: str
    route: str
    roles: tuple[str, ...]
    ready_selector: Optional[str] = None
    ready_text: Optional[str] = None
    required_by_default: bool = True
    variant: str = "stable"


@dataclass(frozen=True)
class WorkflowScenario:
    id: str
    roles: tuple[str, ...]
    menu_page_id: Optional[str] = None
    workflow_kind: str = "drilldown"
    list_route: Optional[str] = None
    detail_href_contains: Optional[str] = None
    search_term: Optional[str] = None
    ready_selector: Optional[str] = None
    ready_text: Optional[str] = None
    required: bool = False
    variant: str = "stable"
    disallowed_detail_href_contains: tuple[str, ...] = ()


PAGE_SCENARIOS: Dict[str, PageScenario] = {
    "dashboard": PageScenario(
        id="dashboard",
        route="/",
        roles=("admin",),
        ready_selector="#foreman-page",
        ready_text="Overview",
        required_by_default=False,
    ),
    "hosts": PageScenario(
        id="hosts",
        route="/hosts",
        roles=("admin", "viewer"),
        ready_text="Hosts",
    ),
    "hosts_new": PageScenario(
        id="hosts_new",
        route="/new/hosts",
        roles=("admin", "viewer"),
        ready_text="Hosts",
        required_by_default=False,
        variant="new",
    ),
    "job_invocations": PageScenario(
        id="job_invocations",
        route="/job_invocations",
        roles=("admin", "viewer"),
        ready_text="Job invocations",
    ),
    # Temporarily disabled until the legacy route is confirmed in the UI.
    # "job_invocations_legacy": PageScenario(
    #     id="job_invocations_legacy",
    #     route="/legacy/job_invocations",
    #     roles=("admin", "viewer"),
    #     ready_text="Job invocations",
    #     required_by_default=False,
    #     variant="legacy",
    # ),
    "tasks": PageScenario(
        id="tasks",
        route="/foreman_tasks/tasks",
        roles=("admin", "viewer"),
        ready_selector="main#foreman-main-container",
        ready_text="Tasks",
    ),
    "content_views": PageScenario(
        id="content_views",
        route="/content_views",
        roles=("admin",),
        ready_text="Content Views",
    ),
}


WORKFLOW_SCENARIOS: Dict[str, WorkflowScenario] = {
    "login_to_dashboard": WorkflowScenario(
        id="login_to_dashboard",
        roles=("admin", "viewer"),
        required=True,
    ),
    "hosts_list_to_details": WorkflowScenario(
        id="hosts_list_to_details",
        roles=("admin", "viewer"),
        menu_page_id="hosts",
        list_route="/hosts",
        detail_href_contains="/hosts/",
        ready_text="Hosts",
        required=True,
        disallowed_detail_href_contains=("/hosts/new",),
    ),
    "hosts_new_list_to_details": WorkflowScenario(
        id="hosts_new_list_to_details",
        roles=("admin", "viewer"),
        menu_page_id="hosts_new",
        list_route="/new/hosts",
        detail_href_contains="/hosts/",
        ready_text="Hosts",
        variant="new",
        disallowed_detail_href_contains=("/hosts/new",),
    ),
    "job_invocations_list_to_details": WorkflowScenario(
        id="job_invocations_list_to_details",
        roles=("admin", "viewer"),
        menu_page_id="job_invocations",
        list_route="/job_invocations",
        detail_href_contains="/job_invocations/",
        ready_text="Job invocations",
        required=True,
    ),
    "job_invocations_legacy_list_to_details": WorkflowScenario(
        id="job_invocations_legacy_list_to_details",
        roles=("admin", "viewer"),
        menu_page_id="job_invocations_legacy",
        list_route="/legacy/job_invocations",
        detail_href_contains="/job_invocations/",
        ready_text="Job invocations",
        variant="legacy",
    ),
    "content_views_list_to_details": WorkflowScenario(
        id="content_views_list_to_details",
        roles=("admin",),
        menu_page_id="content_views",
        list_route="/content_views",
        detail_href_contains="/content_views/",
        ready_text="Content Views",
        disallowed_detail_href_contains=("/content_views/new",),
    ),
    "content_hosts_list_to_details": WorkflowScenario(
        id="content_hosts_list_to_details",
        roles=("admin",),
        menu_page_id="content_hosts",
        list_route="/content_hosts",
        detail_href_contains="/content_hosts/",
        ready_text="Content Hosts",
        disallowed_detail_href_contains=("/content_hosts/new",),
    ),
    "activation_keys_list_to_details": WorkflowScenario(
        id="activation_keys_list_to_details",
        roles=("admin",),
        menu_page_id="activation_keys",
        list_route="/activation_keys",
        detail_href_contains="/activation_keys/",
        ready_text="Activation Keys",
        disallowed_detail_href_contains=("/activation_keys/new",),
    ),
    "products_list_to_details": WorkflowScenario(
        id="products_list_to_details",
        roles=("admin",),
        menu_page_id="products",
        list_route="/products",
        detail_href_contains="/products/",
        ready_text="Products",
        disallowed_detail_href_contains=("/products/new",),
    ),
    "repositories_list_to_details": WorkflowScenario(
        id="repositories_list_to_details",
        roles=("admin",),
        menu_page_id="red_hat_repositories",
        workflow_kind="search",
        list_route="/redhat_repositories",
        search_term="BaseOS",
        ready_text="Red Hat Repositories",
    ),
}


ROUTE_TO_PAGE_ID = {
    "/": "dashboard",
    "/hosts": "hosts",
    "/new/hosts": "hosts_new",
    "/job_invocations": "job_invocations",
    "/legacy/job_invocations": "job_invocations_legacy",
    "/foreman_tasks/tasks": "tasks",
    "/content_views": "content_views",
    "/redhat_repositories": "red_hat_repositories",
}


def page_ids_for_role(role: str) -> List[str]:
    return [page_id for page_id, scenario in PAGE_SCENARIOS.items() if role in scenario.roles]


def workflow_ids_for_role(role: str) -> List[str]:
    return [workflow_id for workflow_id, scenario in WORKFLOW_SCENARIOS.items() if role in scenario.roles]
