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

import svgwrite


per_page = 100


# Where to get the certs:
#
# curl --cacert /etc/pki/katello/certs/katello-server-ca.crt --cert /etc/pki/katello/certs/pulp-client.crt --key /etc/pki/katello/private/pulp-client.key https://$(hostname -f)/pulp/api/v3/tasks/
#
# In my case this had to run against Capsule

def get_json(hostname, uri, params=None):
    r = requests.get(
            "https://%s%s" % (hostname, uri),
            params=params,
            cert=('/tmp/pulp-client.crt', '/tmp/pulp-client.key'),
            verify=False)
    try:
        return r.json()
    except simplejson.scanner.JSONDecodeError:
        logging.error("Error parsing json: %s" % r.text)
        sys.exit(1)


def get_all(hostname, uri, params=None, cache=None):
    if cache and os.path.exists(cache):
        logging.debug("Loading from chache %s" % cache)
        with open(cache, 'r') as fp:
            return json.load(fp)
    out = []
    if params is None:
        params = {'limit': per_page}
    if 'limit' not in params:
        params['limit'] = per_page
    page = 1
    while True:
        params['offset'] = (page - 1) * params['limit']
        r = get_json(hostname, uri, params)
        out += r['results']
        if len(r['results']) == 0:
            if cache:
                logging.debug("Writing to chache %s" % cache)
                with open(cache, 'w') as fp:
                    json.dump(out, fp)
            return out
        page += 1


#    {
#      "pulp_href": "/pulp/api/v3/tasks/b4370b9a-e8fe-45a4-ba0c-bcff9a00d243/",
#      "pulp_created": "2021-11-11T16:05:59.652668Z",
#      "state": "completed",
#      "name": "pulpcore.app.tasks.base.general_update",
#      "logging_cid": "4e46cec7-5937-4178-ad8b-828cc3da47ac",
#      "started_at": "2021-11-11T16:05:59.731178Z",
#      "finished_at": "2021-11-11T16:06:00.121109Z",
#      "error": null,
#      "worker": "/pulp/api/v3/workers/79f13eac-7fda-4705-8e11-83f18c24ccec/",
#      "parent_task": null,
#      "child_tasks": [],
#      "task_group": null,
#      "progress_reports": [],
#      "created_resources": [],
#      "reserved_resources_record": [
#        "/api/v3/distributions/"
#      ]
#    },
#    {
#      "pulp_href": "/pulp/api/v3/tasks/d3ca9604-60b6-482f-bac6-7348826005ea/",
#      "pulp_created": "2021-11-11T16:05:44.026674Z",
#      "state": "completed",
#      "name": "pulpcore.app.tasks.base.general_update",
#      "logging_cid": "4e46cec7-5937-4178-ad8b-828cc3da47ac",
#      "started_at": "2021-11-11T16:05:44.107902Z",
#      "finished_at": "2021-11-11T16:05:44.492160Z",
#      "error": null,
#      "worker": "/pulp/api/v3/workers/99b50e7b-2444-441b-b586-5a4848063ccd/",
#      "parent_task": null,
#      "child_tasks": [],
#      "task_group": null,
#      "progress_reports": [],
#      "created_resources": [],
#      "reserved_resources_record": [
#        "/api/v3/distributions/"
#      ]
#    },

def investigate_task(args):
    tasks = get_all(
        args.hostname, "/pulp/api/v3/tasks/",
        {"logging_cid": args.logging_cid},
        args.cache)

    # Find out time when this started, ended, list of workers and create
    # simplified list of tasks
    tasks_simple = []
    workers = set()
    min_time = datetime.datetime.utcnow().replace(tzinfo=datetime.timezone.utc).timestamp()
    max_time = 0
    for t in tasks:
        ###print(f"{t['name']} {t['pulp_href']} {t['state']} {t['pulp_created']} {t['started_at']} {t['finished_at']} {t['child_tasks']}")
        pulp_created = datetime.datetime.fromisoformat(t['pulp_created'].replace('Z', '+00:00')).timestamp()
        started_at = datetime.datetime.fromisoformat(t['started_at'].replace('Z', '+00:00')).timestamp()
        finished_at = datetime.datetime.fromisoformat(t['finished_at'].replace('Z', '+00:00')).timestamp()
        min_time = pulp_created if pulp_created < min_time else min_time
        min_time = started_at if started_at < min_time else min_time
        max_time = finished_at if finished_at > max_time else max_time
        tasks_simple.append({
            'name': t['name'],
            'pulp_href': t['pulp_href'],
            'pulp_created': pulp_created,
            'started_at': started_at,
            'finished_at': finished_at,
            'worker': t['worker'],
        })
        workers.add(t['worker'])
    print(f"Min / max time: {min_time} / {max_time}")

    # Make times in our tasks list start at min_time (i.e. from zero)
    for t in tasks_simple:
        t['pulp_created'] -= min_time
        t['started_at'] -= min_time
        t['finished_at'] -= min_time

    # Split tasks into per worker lanes (I ssume it it threads)
    workers_threads = {w: [] for w in workers}
    for t in tasks_simple:
        found_home = False
        for thread in workers_threads[t['worker']]:
            fits_into_thread = True
            for i in thread:
                if i['pulp_created'] <= t['pulp_created'] <= i['finished_at'] \
                   or i['pulp_created'] <= t['finished_at'] <= i['finished_at']:
                    fits_into_thread = False
            if fits_into_thread:
                thread.append(t)
                found_home = True
                break
        if not found_home:
            new_thread = [t]
            workers_threads[t['worker']].append(new_thread)

    # Add a empty lane at the end of each worker section
    for worker, threads in workers_threads.items():
        threads.append([])

    # Create drawing object
    lanes = sum([len(threads) for threads in workers_threads.values()])
    print(f"Workers / total threads: {len(workers_threads)} / {lanes}")
    width = max_time - min_time
    height = 50 * (lanes + 1)
    drawing = svgwrite.drawing.Drawing(filename='/tmp/noname.svg', size=(width, height))

    # Draw all the tasks
    tasks_simple = sorted(tasks_simple, key=lambda x: x['pulp_created'])
    lane = -1
    for worker, threads in workers_threads.items():
        worker_label_space = 50
        if worker is None:
            worker_name = 'Unknown'
        else:
            worker_name = worker.replace('/pulp/api/v3/workers/', '').replace('/', '')
        x = 15
        y = 50 * (lane + 1)
        element = svgwrite.text.Text(worker_name, insert=(x, y), style="font-size: 30;", transform=f"rotate(90, {x}, {y})")
        drawing.add(element)

        for thread in threads:
            lane += 1
            for t in thread:

                # Box with pulp_created <--> finished_at
                x = worker_label_space + t['pulp_created']
                y = 50 * lane
                w = t['finished_at'] - t['pulp_created']
                h = 45
                element = svgwrite.shapes.Rect(insert=(x, y), size=(w, h), stroke='#000', fill='#aac')
                drawing.add(element)

                # If box is big enough, create its description
                deserves_description = w / 6 > len(t['name'])
                if deserves_description:
                    x = x
                    y = y + 25
                    element_description = svgwrite.text.Text(t['name'], insert=(x, y), style="font-size: 20;")

                # Box with started_at <--> finished_at
                x = worker_label_space + t['started_at'] + 1
                y = 50 * lane + 1
                w = t['finished_at'] - t['started_at'] - 2
                h = 45 - 2
                element = svgwrite.shapes.Rect(insert=(x, y), size=(w, h), stroke='#00a', fill='#00a')
                drawing.add(element)

                # If box is big enough, add task description so it is after both boxes so will be rendered above them
                if deserves_description:
                    drawing.add(element_description)

    # Save drawing
    drawing.save()


def doit():
    parser = argparse.ArgumentParser(
        description='Show how Pulp3 tasks with common tracking ID flowed',
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument('--hostname', required=True,
                        help='Satellite/Capsule hostname')
    parser.add_argument('--logging_cid', required=True,
                        help='Tracking ID of tasks to investigate')
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

    logging.debug("Args: %s" % args)

    return investigate_task(args)


if __name__ == '__main__':
    sys.exit(doit())
