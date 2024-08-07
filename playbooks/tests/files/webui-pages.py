#!/usr/bin/env python3

import argparse
import inspect
import itertools
import logging
import re
import sys

from locust import HttpUser, FastHttpUser
from locust import constant
from locust import task

import opl.args
import opl.gen
import opl.locust
import opl.skelet

import requests

import urllib3


urllib3.disable_warnings()


def _get(client, uri, pattern, headers={}):
    """
    Simple wrapper around GET requests used by tasks below.

    It just performs the get request, checks status code and checks
    if expected string is there in the output.
    """
    with client.get(uri, headers=headers, verify=False, name=inspect.stack()[1][3], catch_response=True) as response:
        try:
            response.raise_for_status()
        except Exception as e:
            logging.warning(f"Error while accessing {uri}: {e}")
            return response.failure(str(e))

        if re.search(pattern, response.text) is None:
            if "No such file or directory @ rb_sysopen" in response.text:
                return response.failure("Known issue: No such file or directory @ rb_sysopen")
            else:
                logging.warning(f"Got wrong response for {uri}: [{response.status_code}] {response.text}")
                return response.failure("Got wrong response")


class SatelliteWebUIPerfStaticAssets(FastHttpUser):
    wait_time = constant(0)

    def on_start(self):
        """
        Load list of static assets we are going to query.

        Warning: Runtime of this function is part of the test duration :-/
        """
        self.index = 0
        self.urls = []
        with requests.get(f"{self.host_base}/users/login", verify=False) as response:
            find_links = re.finditer(r'<link[^>]* href="(/[^"]+)" ?[^>]*>', response.text)
            find_scripts = re.finditer(r'<script[^>]* src="(/[^"]+)" ?[^>]*>', response.text)
            for match in itertools.chain(find_links, find_scripts):
                uri = match.group(1)
                addit = True
                if self.satellite_max_static_size > 0:
                    with requests.get(f"{self.host_base}{uri}", verify=False, stream=True) as response:
                        size = 0
                        for chunk in response.iter_content(8196):
                            size += len(chunk)
                            if size > self.satellite_max_static_size:
                                logging.debug(f"Not adding {uri} URI because its size is {size} and still streaming")
                                addit = False
                                break
                if addit:
                    logging.debug(f"Adding {uri} URI")
                    self.urls.append(uri)
        logging.info(f"Loaded {len(self.urls)} URLs")

    @task
    def get(self):
        headers = {
            "Accept": "*/*",
            "Accept-Encoding": "gzip, deflate, br",
            "Accept-Language": "en-US,en;q=0.5",
            "Connection": "keep-alive",   # default on HTTP/1.1 anyway
        }
        self.client.get(self.urls[self.index], headers=headers)
        self.index = self.index + 1 if self.index + 1 < len(self.urls) else 0


class SatelliteWebUIPerfNoAuth(HttpUser):
    wait_time = constant(0)

    @task
    def users_login(self):
        _get(self.client, "/users/login", "<title>Login</title>")

    @task
    def pub_bootstrap_py(self):
        _get(self.client, "/pub/bootstrap.py", "Script to register a new host to Foreman/Satellite")


class SatelliteWebUIPerf(HttpUser):
    wait_time = constant(0)

    def on_start(self):
        """
        Get CSRF token, use it in login call and that populates session
        cookie so we can access pages. Some older text about it:
        https://mojo.redhat.com/groups/satellite6qe/blog/2018/08/14/maybe-you-need-to-load-satellite-6-ui-page-without-selenium
        """
        response = self.client.get("/users/login", verify=False, name="users_login_get", catch_response=True)
        try:
            # csrf_token = self.client.cookies["csrf-token"]
            # <meta name="csrf-token" content="pN+PkZI8OHLvYlXPXisAbwRVXeSm8hcNk5LKuysAvD979wlbEPQX+/yn0PBouxkxChEAttUMUms0V9ANDrZyLQ==" />
            csrf_token = re.search("<meta name=\"csrf-token\" content=\"([0-9a-zA-Z+-/=]+?)\" />", response.text).group(1)
        except AttributeError:
            logging.fatal("Unable to gather CSRF token")
            raise
        payload = {
            "authenticity_token": csrf_token,
            "login[login]": self.satellite_username,
            "login[password]": self.satellite_password,
        }
        response = self.client.post("/users/login", data=payload, verify=False, name="users_login_post", catch_response=True)
        if "<title>Login</title>" in response.text:
            logging.fatal("Login failed")
            self.interrupt()

    @task
    def overview(self):
        _get(self.client, "/", "<title>Overview</title>")

    @task
    def job_invocations(self):
        _get(self.client, "/job_invocations", "<title>Job invocations</title>")

    @task
    def foreman_tasks_tasks(self):
        _get(self.client, "/foreman_tasks/tasks", "<foreman-react-component name=\"ForemanTasks\"")

    @task
    def foreman_tasks_api_tasks_include_permissions_true(self):
        _get(self.client, "/foreman_tasks/api/tasks?include_permissions=true", "\"total\"")

    @task
    def hosts(self):
        _get(self.client, "/hosts", "<title>Hosts</title>")

    @task
    def templates_provisioning_templates(self):
        _get(self.client, "/templates/provisioning_templates", "<title>Provisioning Templates</title>")

    @task
    def hostgroups(self):
        _get(self.client, "/hostgroups", "<title>Host Groups</title>")

    @task
    def smart_proxies(self):
        _get(self.client, "/smart_proxies", "<title>Capsules</title>")

    @task
    def domains(self):
        _get(self.client, "/domains", "<title>Domains</title>")

    @task
    def audits(self):
        _get(self.client, "/audits", "<foreman-react-component name=\"ReactApp\" data-props=\".*Audits")

    @task
    def audits_page_per_page_search(self):
        _get(self.client, "/audits?page=1&per_page=20&search=", "\"audits\"", headers={"Accept": "application/json"})

    @task
    def organizations(self):
        _get(self.client, "/organizations", "<title>Organizations</title>")

    @task
    def locations(self):
        _get(self.client, "/locations", "<title>Locations</title>")

    @task
    def katello_api_v2_products_organization_id(self):
        _get(self.client, f"/katello/api/v2/products?organization_id={self.satellite_org_id}", "\"results\":")

    @task
    def katello_api_v2_content_views_nondefault_organization_id(self):
        _get(self.client, f"/katello/api/v2/content_views?nondefault=true&organization_id={self.satellite_org_id}", "\"results\":")

    @task
    def katello_api_v2_packages_organization_id(self):
        _get(self.client, f"/katello/api/v2/packages?organization_id={self.satellite_org_id}&paged=true&search=", "\"results\":")

    @task
    def pub(self):
        _get(self.client, "/pub", "<title>Index of /pub</title>")

    @task
    def api_ping(self):
        _get(self.client, "/api/ping", "\"results\":")

    @task
    def pulp_api_v3_status(self):
        _get(self.client, "/pulp/api/v3/status", "\"versions\":")

    @task
    def rhsm(self):
        _get(self.client, "/rhsm", "\"consumers\"")

    @task
    def rhsm_status(self):
        _get(self.client, "/rhsm/status", "\"mode\":")


def doit(args, status_data):
    test_set = getattr(sys.modules[__name__], args.test_set)
    test_set.host_base = f"{args.host}{args.test_url_suffix}"
    test_set.satellite_version = args.satellite_version
    test_set.satellite_org_id = args.satellite_org_id
    test_set.satellite_username = args.satellite_username
    test_set.satellite_password = args.satellite_password
    test_set.satellite_max_static_size = args.satellite_max_static_size

    # Add parameters to status data file
    status_data.set('name', f'Satellite UI perf test, concurrency { args.num_clients }, duration { args.test_duration }')
    status_data.set('parameters.test.test_set', args.test_set)
    status_data.set('parameters.test.satellite_version', args.satellite_version)
    status_data.set('parameters.test.satellite_org_id', args.satellite_org_id)
    status_data.set('parameters.test.satellite_username', args.satellite_username)
    status_data.set('parameters.test.satellite_max_static_size', args.satellite_max_static_size)

    return opl.locust.run_locust(args, status_data, test_set, new_stats=True, summary_only=True)


def main():
    """
    Parse arguments, call doit
    """

    parser = argparse.ArgumentParser(
        description='Measure Satellite WebUI performance',
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        '--test-set',
        default='SatelliteWebUIPerf',
        choices=['SatelliteWebUIPerf', 'SatelliteWebUIPerfNoAuth', 'SatelliteWebUIPerfStaticAssets'],
        help='What test set to use?',
    )
    parser.add_argument(
        '--satellite-version',
        default='6.12',
        help='What Satellite version is this?',
    )
    parser.add_argument(
        '--satellite-org_id',
        default='1',
        type=int,
        help='Satellite organization ID',
    )
    parser.add_argument(
        '--satellite-username',
        default='admin',
        help='Satellite username',
    )
    parser.add_argument(
        '--satellite-password',
        default='password',
        help='Satellite password',
    )
    parser.add_argument(
        '--satellite-max-static-size',
        default=0,
        type=int,
        help='For SatelliteWebUIPerfStaticAssets, this is max size of the asset when running the test. Use 0 for no limit',
    )
    opl.args.add_locust_opts(parser)
    with opl.skelet.test_setup(parser) as (args, status_data):
        return doit(args, status_data)


if __name__ == "__main__":
    sys.exit(main())
