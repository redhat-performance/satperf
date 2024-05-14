#!/usr/bin/env python3

"""
Satellite API doc:

    https://<hostname>/apidoc/v2

Using the API:

    curl --silent --insecure -u <user>:<pass> -X GET -H 'Accept: application/json' -H 'Content-Type: application/json' https://localhost/api/v2/job_invocations/6
    curl --silent --insecure -u <user>:<pass> -X GET -H 'Accept: application/json' -H 'Content-Type: application/json' https://localhost/foreman_tasks/api/tasks/a1845242-34cc-44b7-ae24-f8a1c5748641
"""

import argparse
import logging
import requests
import simplejson.scanner
import sys
import time
import urllib3

from tenacity import *


@retry(stop=(stop_after_delay(10) | stop_after_attempt(10)))
def get_json(hostname, uri, username, password):
    r = requests.get(
      f"https://{hostname}{uri}",
      auth=(username, password),
      verify=False
    )
    try:
        return r.json()
    except simplejson.scanner.JSONDecodeError:
        logging.error(f"Error parsing json: {r.text}")
        sys.exit(1)


@retry(stop=(stop_after_delay(10) | stop_after_attempt(10)))
def post_json(hostname, uri, username, password):
    r = requests.post(
      f"https://{hostname}{uri}",
      auth=(username, password),
      headers={'content-type': 'application/json'},
      verify=False
    )
    try:
        return r.json()
    except simplejson.scanner.JSONDecodeError:
        logging.error("Error parsing json: {r.text}")
        sys.exit(1)


def wait_for_job(args):
    # Wait until we get the task ID
    while True:
        # Search for the job_id instead of providing it directly to avoid showing
        # the list of hosts (default with 'Any Location')
        job_json = get_json(
          args.hostname,
          f"/api/job_invocations?search=id={args.job_id}",
          args.username,
          args.password
        )
        if job_json['results'][0]['dynflow_task']:
            if job_json['results'][0]['dynflow_task']['state'] in ('running', 'stopped'):
                task_id = job_json['results'][0]['dynflow_task']['id']
                break
        else:
            time.sleep(5)

    while True:
        task_json = get_json(
          args.hostname,
          f"/foreman_tasks/api/tasks/{task_id}",
          args.username,
          args.password
        )
        if task_json['output']:
            break
        else:
            time.sleep(10)

    total_count_before = task_json['output']['total_count']
    timeout_counter = 0

    while True:
        if task_json['pending']:
            time.sleep(60)

            while True:
                task_json = get_json(
                  args.hostname,
                  f"/foreman_tasks/api/tasks/{task_id}",
                  args.username,
                  args.password
                )
                if task_json['output']:
                    break
                else:
                    time.sleep(10)

            total_count_current = task_json['output']['total_count']
            if total_count_before == total_count_current:
                timeout_counter += 1
            else:
                total_count_before = total_count_current
                timeout_counter = 0

            if timeout_counter == args.timeout:
                post_json(
                  args.hostname,
                  f"/api/job_invocations/{args.job_id}/cancel?force=true",
                  args.username,
                  args.password
                )

                time.sleep(60)

                sys.exit(2)
        else:
            break


def doit():
    parser = argparse.ArgumentParser(
        description='Wait for the job invocation provided to finish or error out',
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument('--hostname', required=True,
                        help='Satellite hostname')
    parser.add_argument('-u', '--username', default='admin',
                        help='Satellite username')
    parser.add_argument('-p', '--password', default='changeme',
                        help='Satellite password')
    parser.add_argument('--job-id', required=True,
                        help='Job invocation ID you want to investigate')
    parser.add_argument('--timeout', type=int, default=15,
                        help='How long to wait for the underlying task to show progress (in minutes). The progress will be measured against the sum of the failed an successful sub-tasks')
    parser.add_argument('--dont-hide-warnings', action='store_true',
                        help='Show urllib3 warnings like InsecureRequestWarning')
    parser.add_argument('-d', '--debug', action='store_true',
                        help='Show debug output')
    args = parser.parse_args()

    if args.debug:
        logging.basicConfig(level=logging.DEBUG)

    if not args.dont_hide_warnings:
        urllib3.disable_warnings()

    logging.debug(f"Args: {args}")

    return wait_for_job(args)


if __name__ == '__main__':
    sys.exit(doit())
