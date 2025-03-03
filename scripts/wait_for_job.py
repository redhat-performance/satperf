#!/usr/bin/env python3

"""
Satellite API doc:

    https://<hostname>/apidoc/v2

Using the API:

    curl --silent --insecure -u <user>:<pass> -X GET -H 'Accept: application/json' -H 'Content-Type: application/json' https://localhost/api/v2/job_invocations/6
    curl --silent --insecure -u <user>:<pass> -X GET -H 'Accept: application/json' -H 'Content-Type: application/json' https://localhost/foreman_tasks/api/tasks/a1845242-34cc-44b7-ae24-f8a1c5748641
"""

import argparse
import json
import logging
import requests
import sys
import time
import urllib3

from datetime import datetime, timezone
from tenacity import *


def log(args):
    utc_dt = datetime.now(timezone.utc)
    iso_date_s = utc_dt.isoformat(timespec='seconds')

    print(f"[{iso_date_s}] {args}")


@retry(stop=(stop_after_delay(10) | stop_after_attempt(10)))
def get_json(hostname, uri, username, password):
    r = requests.get(
      f"https://{hostname}{uri}",
      auth=(username, password),
      verify=False
    )
    try:
        return r.json()
    except json.JSONDecodeError:
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
    except json.JSONDecodeError:
        logging.error("Error parsing json: {r.text}")
        sys.exit(1)


def wait_for_job(args):
    # Wait until a task is created
    while True:
        # Search for the job_id instead of providing it directly to avoid showing
        # the list of hosts (default with 'Any Location')
        job_json = get_json(
          args.hostname,
          f"/api/job_invocations?search=id={args.job_id}",
          args.username,
          args.password
        )
        if ('results' in job_json and
            len(job_json['results']) == 1 and
            'dynflow_task' in job_json['results'][0] and
            job_json['results'][0]['dynflow_task'] is not None and
            'id' in job_json['results'][0]['dynflow_task']):

                break

        time.sleep(10)

    task_id = job_json['results'][0]['dynflow_task']['id']
    success_count_before = failed_count_before = pending_count_before = 0
    timeout_counter = 0

    while True:
        task_json = get_json(
          args.hostname,
          f"/foreman_tasks/api/tasks/{task_id}",
          args.username,
          args.password
        )

        if ('state' in task_json and
            task_json['state'] == 'stopped'):

            break

        if ('output' in task_json and
            task_json['output'] is not None and
            'success_count' in task_json['output'] and
            'failed_count' in task_json['output'] and
            'pending_count' in task_json['output']):
            success_count = task_json['output']['success_count']
            failed_count = task_json['output']['failed_count']
            pending_count = task_json['output']['pending_count']

            if (success_count_before != success_count or
                failed_count_before != failed_count or
                pending_count_before != pending_count):
                timeout_counter = 0

                if success_count_before != success_count:
                    success_count_before = success_count
                if failed_count_before != failed_count:
                    failed_count_before = failed_count
                if pending_count_before != pending_count:
                    pending_count_before = pending_count
            else:
                timeout_counter += 1

                if timeout_counter == args.timeout:
                    post_json(
                    args.hostname,
                    f"/api/job_invocations/{args.job_id}/cancel?force=true",
                    args.username,
                    args.password
                    )

                    log(f"Job invocation {args.job_id} spent more than {args.timeout} minute(s) with no sub-task progress and had to be cancelled")

                    time.sleep(60)

                    task_json = get_json(
                    args.hostname,
                    f"/foreman_tasks/api/tasks/{task_id}",
                    args.username,
                    args.password
                    )

                    break

        time.sleep(60)

    success = task_json['output']['success_count'] if 'success_count' in task_json['output'] else '-'
    total = task_json['output']['total_count'] if 'total_count' in task_json['output'] else '-'
    failed = task_json['output']['failed_count'] if 'failed_count' in task_json['output'] else '-'
    cancelled = task_json['output']['cancelled_count'] if 'cancelled_count' in task_json['output'] else '-'
    pending = task_json['output']['pending_count'] if 'pending_count' in task_json['output'] else '-'

    log(f"Examined job invocation {args.job_id}: {success} / {total} successful executions ({failed} failed / {cancelled} cancelled / {pending} pending)")


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
