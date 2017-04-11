#!/bin/bash

if ! type hammer &>/dev/null; then
  echo "ERROR: Hammer command not available"
  exit 1
fi
if ! type mail &>/dev/null; then
  echo "ERROR: Mail command not available"
  exit 1
fi
if ! type wget &>/dev/null; then
  echo "ERROR: Wget command not available"
  exit 1
fi

function get_col() {
  col="$1"; shift
  hammer --csv --username admin --password changeme "$@" | tail -n 1 | cut -d ',' -f $col
}

function run_job() {
  template="$1"  
  job_query="$2" 

  template_file="rex-template-$template.sh"
  if ! [ -r $template_file ]; then
    echo "ERROR: Template $template_file not readable"
    return 1
  fi

  # Start the job
  log=$( mktemp )
  job_description="$template_file at $( date --iso-8601=seconds )"
  hammer --username admin --password changeme job-invocation create --async --description-format "$job_description" --input-files command=$template_file --job-template "Run Command - SSH Default" --search-query "$job_query" &>$log &
  pid=$!

  # Wait for a job to be started
  attempt=0
  attempt_max=30 
  attempt_sleep=1
  while true; do
    grep -q '^Task [0-9a-f-]\+ \(planned\|running\):' $log && break
    if [ $attempt -gt $attempt_max ]; then
      echo "ERROR: We are out of time when waiting for job to start. Output in $log."
      return 1
    fi
    let attempt+=1
    echo "DEBUG: [$( date --iso-8601=seconds )] Waiting for job '$job_description' to start"
    sleep $attempt_sleep
  done
  kill $pid
  task_uuid=$( grep '^Task [0-9a-f-]\+ \(planned\|running\):' $log | tail -n 1 | sed "s/^Task \([0-9a-f-]\+\) \(planned\|running\):.*/\1/" )
  echo "DEBUG: Task UUID is: $task_uuid"

  # Wait for a job to finish
  job_id=$( get_col 1 job-invocation list --search "description = \"$job_description\"" )
  while get_col 3 job-invocation list --search "description = \"$job_description\"" | grep -q ^running$; do
    echo "DEBUG: [$( date --iso-8601=seconds )] Waiting for job '$job_description' to finish, see https://$( hostname )/job_invocations/$job_id"
    sleep 60
  done

  # Show info about the job
  echo "Job ID: $job_id"
  echo "Job description: $job_description"
  hammer --username admin --password changeme job-invocation info --id $job_id

  # Show info about the task
  echo "Task UUID: $task_uuid"
  hammer --username admin --password changeme task list --search "id = $task_uuid"
  hammer --username admin --password changeme task progress --id "$task_uuid"
}

function doit() {
  mail_log=$( mktemp )
  before=$( date +%s )
  run_job "$1" "$2" &>$mail_log
  rc=$?
  after=$( date +%s )
  wget --quiet -O load.png "http://grafana.example.com:3000/render/dashboard-solo/db/satellite6-general-system-performance?from=$( expr $before - 300 )000&to=$( expr $after )000&orgId=1&var-Cloud=satellite6&var-Node=scale-sat1&var-Interface=interface-eth0&var-Disk=disk-vda&var-cpus0=All&var-cpus00=All&panelId=27&width=1500&height=500&tz=UTC%2B00%3A00"
  wget --quiet -O mem.png "http://grafana.example.com:3000/render/dashboard-solo/db/satellite6-general-system-performance?from=$( expr $before - 300 )000&to=$( expr $after )000&orgId=1&var-Cloud=satellite6&var-Node=scale-sat1&var-Interface=interface-eth0&var-Disk=disk-vda&var-cpus0=All&var-cpus00=All&panelId=56&width=1500&height=500&tz=UTC%2B00%3A00"
  [ "$3" != 'nomail' ] && cat $mail_log | mail -s "job finished: $1" -a load.png -a mem.png jhutar@redhat.com psuriset@redhat.com
  return $rc
}

score=0

doit 'date'         'name ~ r630container AND name !~ c10-h31 AND name !~ c10-h32 AND name !~ c10-h33 AND name ~ container700'
let score+=$?
doit 'repo-enable'  'name ~ r630container AND name !~ c10-h31 AND name !~ c10-h32 AND name !~ c10-h33 AND name ~ container700' 'nomail'
# Not updating score, just to prepare the systems
doit 'repo-disable' 'name ~ r630container AND name !~ c10-h31 AND name !~ c10-h32 AND name !~ c10-h33 AND name ~ container700'
let score+=$?
doit 'repo-enable'  'name ~ r630container AND name !~ c10-h31 AND name !~ c10-h32 AND name !~ c10-h33 AND name ~ container700'
let score+=$?
doit 'profile'      'name ~ r630container AND name !~ c10-h31 AND name !~ c10-h32 AND name !~ c10-h33 AND name ~ container700'
let score+=$?

doit 'date'         'name ~ r630container AND name !~ c10-h31 AND name !~ c10-h32 AND name !~ c10-h33 AND name ~ container70'
let score+=$?
doit 'repo-enable'  'name ~ r630container AND name !~ c10-h31 AND name !~ c10-h32 AND name !~ c10-h33 AND name ~ container70' 'nomail'
# Not updating score, just to prepare the systems
doit 'repo-disable' 'name ~ r630container AND name !~ c10-h31 AND name !~ c10-h32 AND name !~ c10-h33 AND name ~ container70'
let score+=$?
doit 'repo-enable'  'name ~ r630container AND name !~ c10-h31 AND name !~ c10-h32 AND name !~ c10-h33 AND name ~ container70'
let score+=$?
doit 'profile'      'name ~ r630container AND name !~ c10-h31 AND name !~ c10-h32 AND name !~ c10-h33 AND name ~ container70'
let score+=$?

doit 'date'         'name ~ r630container AND name !~ c10-h31 AND name !~ c10-h32 AND name !~ c10-h33 AND ( name ~ container7 OR name ~ container6 )'
let score+=$?
doit 'repo-enable'  'name ~ r630container AND name !~ c10-h31 AND name !~ c10-h32 AND name !~ c10-h33 AND ( name ~ container7 OR name ~ container6 )' 'nomail'
# Not updating score, just to prepare the systems
doit 'repo-disable' 'name ~ r630container AND name !~ c10-h31 AND name !~ c10-h32 AND name !~ c10-h33 AND ( name ~ container7 OR name ~ container6 )'
let score+=$?
doit 'repo-enable'  'name ~ r630container AND name !~ c10-h31 AND name !~ c10-h32 AND name !~ c10-h33 AND ( name ~ container7 OR name ~ container6 )'
let score+=$?
doit 'profile'      'name ~ r630container AND name !~ c10-h31 AND name !~ c10-h32 AND name !~ c10-h33 AND ( name ~ container7 OR name ~ container6 )'
let score+=$?

doit 'date'         'name ~ r630container AND name !~ c10-h31 AND name !~ c10-h32 AND name !~ c10-h33 AND name ~ container'
let score+=$?
doit 'repo-enable'  'name ~ r630container AND name !~ c10-h31 AND name !~ c10-h32 AND name !~ c10-h33 AND name ~ container' 'nomail'
# Not updating score, just to prepare the systems
doit 'repo-disable' 'name ~ r630container AND name !~ c10-h31 AND name !~ c10-h32 AND name !~ c10-h33 AND name ~ container'
let score+=$?
doit 'repo-enable'  'name ~ r630container AND name !~ c10-h31 AND name !~ c10-h32 AND name !~ c10-h33 AND name ~ container'
let score+=$?
doit 'profile'      'name ~ r630container AND name !~ c10-h31 AND name !~ c10-h32 AND name !~ c10-h33 AND name ~ container'
let score+=$?

echo $score
