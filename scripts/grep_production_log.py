#!/usr/bin/env python
import sys
import re

# When you want to grep production.log for some path but you are interested
# in all other lines related to that request (using that request ID (not
# sure how it is called)
#
# Example:
#
#   tail -f /var/log/foreman/production.log | ./grep_production_log.py '/api/v2/job_invocations/[0-9]+/outputs'
#
# Output:
#
#   2021-02-19T09:42:35 [I|app|c68bc264] Started GET "/api/v2/job_invocations/27/outputs?search_query=name+%5E+(satperf006container70.usersys.redhat.com)" for 127.0.0.1 at 2021-02-19 09:42:35 -0500
#   2021-02-19T09:42:35 [I|app|c68bc264] Processing by Api::V2::JobInvocationsController#outputs as JSON
#   2021-02-19T09:42:35 [I|app|c68bc264]   Parameters: {"search_query"=>"name ^ (satperf006container70.usersys.redhat.com)", "apiv"=>"v2", "id"=>"27"}
#   2021-02-19T09:42:35 [I|app|c68bc264] Completed 200 OK in 311ms (Views: 0.5ms | ActiveRecord: 40.9ms | Allocations: 83301)
#   [...]
#
# First line is shown because it matches provided pattern, rest of
# the lines is shown because they have same request ID 'c68bc264'.

regexp = sys.argv[1]
tracker = []
tracker_max = 1000
req_id_regexp = '^[^ ]+ \[[^\|]+\|[^\|]+\|([a-zA-Z0-9]+)\] .*'

for line in sys.stdin:
    line = line.strip()
    if re.search(regexp, line):
        print(line)
        found = re.search(req_id_regexp, line)
        if found:
            req_id = found.group(1)
            if req_id:
                if req_id not in tracker:
                    tracker.append(req_id)
                if len(tracker) > tracker_max:
                    tracker.pop(0)
    else:
        for t in reversed(tracker):
            if '|' + t + '] ' in line:
                print(line)
                break
