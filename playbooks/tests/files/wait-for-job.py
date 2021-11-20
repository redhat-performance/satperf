#!/usr/bin/env python3
# -*- coding: UTF-8 -*-

import json
from simplejson.scanner import JSONDecodeError
import sys
import time
import datetime
import requests
import requests.utils
import pprint

# Because we are unsecure
from requests.packages.urllib3.exceptions import InsecureRequestWarning
requests.packages.urllib3.disable_warnings(InsecureRequestWarning)

USERNAME = sys.argv[1]
PASSWORD = sys.argv[2]
URL = sys.argv[3]
JOB_ID = int(sys.argv[4])

# URL for the API to your deployed Satellite 6 server
SAT_API = "%s/api/v2/" % URL
# Katello-specific API
KATELLO_API = "%s/katello/api/" % URL

POST_HEADERS = {'content-type': 'application/json'}
# Ignore SSL for now
SSL_VERIFY = False


def get_json(location):
    """
    Performs a GET using the passed URL location
    """

    result = requests.get(location, auth=(USERNAME, PASSWORD), verify=SSL_VERIFY)
    print("DEBUG: GET on location %s returned %s" % (location, result))

    assert result.status_code == 200, "ERROR: %s" % result.text
    try:
        return result.json()
    except JSONDecodeError:
        print("ERROR: GET request to %s did not returned JSON but: %s" % (location, result.text))
        sys.exit(1)


def post_json(location, json_data):
    """
    Performs a POST and passes the data to the URL location
    """

    result = requests.post(
        location,
        data=json_data,
        auth=(USERNAME, PASSWORD),
        verify=SSL_VERIFY,
        headers=POST_HEADERS)
    print("DEBUG: POST on location %s returned %s" % (location, result))

    assert result.status_code == 200, "ERROR: %s" % result.text
    try:
        return result.json()
    except JSONDecodeError:
        print("ERROR: POST request to %s did not returned JSON but: %s" % (location, result.text))
        sys.exit(1)

PER_PAGE = 20
STARTED_AT_FMT = "%Y-%m-%d %H:%M:%S %Z"
MAX_AGE = datetime.timedelta(0, 1200)
SLEEP = 15

hanged_tasks = []
while True:
    job_info = get_json(URL + '/api/v2/job_invocations/%s' % JOB_ID)
    ###pprint.pprint(job_info)
    if job_info['status_label'] != 'running':
        print("PASS: Job %s is not running now" % JOB_ID)
        pprint.pprint(job_info)
        break
    if job_info['pending'] == 0:
        print("PASS: There are no pending sub-tasks in job %s now" % JOB_ID)
        pprint.pprint(job_info)
        break
    dynflow_task_id = job_info['dynflow_task']['id']
    dynflow_task_info = get_json(URL + '/foreman_tasks/api/tasks/%s' % dynflow_task_id)
    ###pprint.pprint(dynflow_task_info)
    if 'pending_count' in dynflow_task_info['output']:
        hanged_tasks = []
        now = datetime.datetime.utcnow()
        for page in range(int(dynflow_task_info['output']['pending_count'] / PER_PAGE) + 1):
            data = (page+1, PER_PAGE, requests.utils.quote("parent_task_id = %s AND state != stopped" % dynflow_task_id))
            sub_tasks = get_json(URL + "/foreman_tasks/api/tasks?page=%s&per_page=%s&search=%s" % data)
            ###pprint.pprint(sub_tasks)
            for r in sub_tasks['results']:
                r_started = datetime.datetime.strptime(r['started_at'], STARTED_AT_FMT)
                if now - r_started >= MAX_AGE:
                    ###pprint.pprint(r)
                    hanged_tasks.append(r["id"])
        # If there are only hanged tasks remaining
        if len(hanged_tasks) >= dynflow_task_info['output']['pending_count']:
            print("WARNING: There are %s hanged sub-tasks in job %s, but looks like main task is done" % (len(hanged_tasks), JOB_ID))
            break
    # OK, there are still some tasks running
    time.sleep(SLEEP)

#### Looks like this needs some extra auth token to be able to do this
###for task in hanged_tasks:
###    print ">>> canceling", task
###    print post_json(URL + "/foreman_tasks/tasks/%s/cancel" % task, {})
###    #print post_json(URL + "/foreman_tasks/dynflow/%s/cancel" % task, {})

def to_timestamp(data):
    return int(round((data - datetime.datetime.utcfromtimestamp(0)).total_seconds()))

# Finally get info about jobs
job_info = get_json(URL + '/api/v2/job_invocations/%s' % JOB_ID)
start_at = datetime.datetime.strptime(job_info['start_at'], "%Y-%m-%d %H:%M:%S %Z")
dynflow_task_id = job_info['dynflow_task']['id']
pass_count = 0
pass_sum_seconds = 0
last_ended = None
for page in range(int(job_info['total'] / PER_PAGE) + 1):
    data = (page+1, PER_PAGE, requests.utils.quote("parent_task_id = %s" % dynflow_task_id))
    sub_tasks = get_json(URL + "/foreman_tasks/api/tasks?page=%s&per_page=%s&search=%s" % data)
    ###pprint.pprint(sub_tasks)
    for r in sub_tasks['results']:
        if r['result'] == 'success':
            r_ended = datetime.datetime.strptime(r['ended_at'], STARTED_AT_FMT)
            if last_ended is None or last_ended < r_ended:
                last_ended = r_ended
            r_duration = r_ended - start_at
            pass_count += 1
            pass_sum_seconds += r_duration.seconds
data = {
    'pass_count': pass_count,
    'total_count': job_info['total'],
    'start_at': start_at,
    'end_at': last_ended,
    'total_test_time': to_timestamp(last_ended)-to_timestamp(start_at),
    'avg_duration': int(round(float(pass_sum_seconds) / pass_count))}
print("RESULT passed {pass_count} of {total_count} started {start_at} ended {end_at} Total time {total_test_time} avg {avg_duration} seconds".format(**data))
