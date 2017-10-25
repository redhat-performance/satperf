#!/usr/bin/env python
# -*- coding: UTF-8 -*-

import sys
import datetime
import dateutil.parser
import collections
import requests
import pprint

username = sys.argv[1]
password = sys.argv[2]
server = sys.argv[3]
task_id = sys.argv[4]

# Ignore time when less then this percentage of jobs were running
# E.g. When we have job with 100 sub-tasks, percentage 5 would ignore
# time from beginning and from end when less than 5 sub-tasks were
# running (so 3 stucked sub-cases wont affect conted duration of
# the main task)
if len(sys.argv) == 6:
    percentage = float(sys.argv[5])
else:
    percentage = 3

per_page = 100
datetime_fmt = "%Y-%m-%d %H:%M"

def get_json(uri, params=None):
    r = requests.get(
            "https://%s%s" % (server, uri),
            params=params,
            auth=(username, password),
            verify=False)
    return r.json()

def get_all(uri, params=None):
    out = []
    if params is None:
        params = {'per_page': per_page}
    if 'per_page' not in params:
        params['per_page'] = per_page
    page = 1
    while True:
        params['page'] = page
        r = get_json(uri, params)
        out += r['results']
        if int(r['page']) * int(r['per_page']) >= int(r['total']):
            return out
        page += 1
        ###return out   # DEBUG: del me

parent_task = get_json("/foreman_tasks/api/tasks/%s" % task_id)
if parent_task['state'] != 'stopped':
    pprint.pprint(parent_task)
    print "ERROR: Parent task not finished yet"
    sys.exit(1)

sub_tasks = get_all("/foreman_tasks/api/tasks", {"search": "parent_task_id = %s" % task_id})
###with open('cache', 'w') as fp:
###    import json
###    json.dump(sub_tasks, fp)
###with open('cache', 'r') as fp:
###    import json
###    sub_tasks = json.load(fp)

print "DEBUG: Task %s have %s sub-tasks" % (task_id, len(sub_tasks))
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

max_val = float(count) * percentage / 100
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
print "When removed start and end of task with less than %.2f of running tasks, task started at %s, finished at %s and lasted for %s" % (max_val, start, end, end - start)
