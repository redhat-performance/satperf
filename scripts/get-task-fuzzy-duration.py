#!/usr/bin/env python3

import logging
import sys
import datetime
import dateutil.parser
import collections
import requests
import argparse
import urllib3
import simplejson.scanner

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


def get_all(hostname, uri, username, password, params=None):
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
        {"search": "parent_task_id = %s" % args.task_id})
    # with open('cache', 'w') as fp:
    #     import json
    #     json.dump(sub_tasks, fp)
    # with open('cache', 'r') as fp:
    #     import json
    #     sub_tasks = json.load(fp)

    logging.debug("Task %s have %s sub-tasks" % (args.task_id, len(sub_tasks)))
    count = 0
    data = {}
    minute = datetime.timedelta(0, 60, 0)
    for t in sub_tasks:
        count += 1
        s = dateutil.parser.parse(t['started_at'])
        e = dateutil.parser.parse(t['ended_at'])
        key = s
        while key <= e:
            key_str = key.strftime(datetime_fmt)
            if key_str not in data:
                data[key_str] = 0
            data[key_str] += 1
            key += minute
    data = collections.OrderedDict(sorted(data.items(), key=lambda t: t[0]))
    print(data)

    max_val = float(count) * args.percentage / 100
    start = None
    for key, val in data.items():
        if val > max_val:
            start = dateutil.parser.parse(key)
            break
    end = None
    for key, val in reversed(data.items()):
        if val > max_val:
            end = dateutil.parser.parse(key)
            break
    print("When removed start and end of task with less than %.2f of running tasks, task started at %s, finished at %s and lasted for %s" % (max_val, start, end, end - start))   # noqa: E501


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
                        help='Cache data to this file, do not cache when empty')
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
