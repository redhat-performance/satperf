#!/usr/bin/env python3

import logging
import sys
import os.path
import datetime
import dateutil.parser
import collections
import requests
import argparse
import urllib3
import simplejson.scanner
import json

per_page = 100
datetime_fmt = "%Y-%m-%d %H:%M"


def get_json(hostname, uri, username, password, params=None):
    r = requests.get(
            "https://%s%s" % (hostname, uri),
            params=params,
            auth=(username, password),
            verify=False)
    try:
        return r.json()
    except simplejson.scanner.JSONDecodeError:
        logging.error("Error parsing json: %s" % r.text)
        sys.exit(1)


def get_all(hostname, uri, username, password, params=None, cache=None):
    if cache and os.path.exists(cache):
        logging.debug("Loading from chache %s" % cache)
        with open(cache, 'r') as fp:
            return json.load(fp)
    out = []
    if params is None:
        params = {'per_page': per_page}
    if 'per_page' not in params:
        params['per_page'] = per_page
    page = 1
    while True:
        params['page'] = page
        r = get_json(hostname, uri, username, password, params)
        out += r['results']
        if int(r['page']) * int(r['per_page']) >= int(r['subtotal']):
            if cache:
                logging.debug("Writing to chache %s" % cache)
                with open(cache, 'w') as fp:
                    json.dump(out, fp)
            return out
        page += 1


def investigate_task(args):
    parent_task = get_json(
        args.hostname, "/foreman_tasks/api/tasks/%s" % args.task_id,
        args.username, args.password)
    if 'error' in parent_task:
        logging.error("Error retrieving parent task info: %s" % parent_task)
        sys.exit(1)
    if 'state' not in parent_task:
        logging.error("Unexpected parent task format, missing 'state': %s"
                      % parent_task)
        sys.exit(1)
    if parent_task['state'] != 'stopped':
        logging.error("Parent task not finished yet: %s" % parent_task)
        sys.exit(1)

    sub_tasks = get_all(
        args.hostname, "/foreman_tasks/api/tasks",
        args.username, args.password,
        {"search": "parent_task_id = %s" % args.task_id},
        args.cache)
    # with open('cache', 'w') as fp:
    #     import json
    #     json.dump(sub_tasks, fp)
    # with open('cache', 'r') as fp:
    #     import json
    #     sub_tasks = json.load(fp)

    logging.debug("Task %s have %s sub-tasks" % (args.task_id, len(sub_tasks)))

    count = len(sub_tasks)
    starts = [dateutil.parser.parse(t['started_at']) for t in sub_tasks]
    ends = [dateutil.parser.parse(t['ended_at']) for t in sub_tasks]

    starts.sort()
    ends.sort()

    start = min(starts)
    end = max(ends)

    print("From all sub-tasks data, task started at %s, finished at %s and lasted for %s" % (start, end, end - start))   # noqa: E501

    to_remove = round((args.percentage / 100) * count)
    starts_cleaned = starts[to_remove:]
    ends_cleaned = ends[:-to_remove]

    start_cleaned = min(starts_cleaned)
    end_cleaned = max(ends_cleaned)

    print("When removed head and tail with less than %.2f%% of running sub-tasks, task started at %s, finished at %s and lasted for %s" % (args.percentage, start_cleaned, end_cleaned, end_cleaned - start_cleaned))   # noqa: E501

    head = start_cleaned - start
    tail = end - end_cleaned

    print("So head lasted %s and tail %s, which is %.2f%% of total time" % (head, tail, (head + tail) / (end - start) * 100))


def doit():
    parser = argparse.ArgumentParser(
        description='Show task duration with given percentage of hanged sub-tasks removed from the equation',
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument('-u', '--username', default='admin',
                        help='Satellite username')
    parser.add_argument('-p', '--password', default='changeme',
                        help='Satellite password')
    parser.add_argument('--hostname', required=True,
                        help='Satellite hostname')
    parser.add_argument('--task-id', required=True,
                        help='Task ID you want to investigate')
    parser.add_argument('--percentage', type=float, default=3,
                        help='How many %% of longest sub-tasks to ignore')
    parser.add_argument('--cache',
                        help='Cache sub-tasks data to this file. Do not cache when option is not provided. Meant for debugging as it does not care about other parameters, it just returns cache content.')
    parser.add_argument('--dont-hide-warnings', action='store_true',
                        help='Show urllib3 warnings like InsecureRequestWarning')
    parser.add_argument('-d', '--debug', action='store_true',
                        help='Show debug output')
    args = parser.parse_args()

    if args.debug:
        logging.basicConfig(level=logging.DEBUG)

    if not args.dont_hide_warnings:
        urllib3.disable_warnings()

    logging.debug("Args: {args}")

    return investigate_task(args)


if __name__ == '__main__':
    sys.exit(doit())
