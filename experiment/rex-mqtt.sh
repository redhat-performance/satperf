#!/bin/sh

source experiment/run-library.sh

organization="${PARAM_organization:-Default Organization}"
inventory="${PARAM_inventory:-conf/contperf/inventory.ini}"
local_conf="${PARAM_local_conf:-conf/satperf.local.yaml}"

wait_interval=${PARAM_wait_interval:-50}

dl="Default Location"

opts="--forks 100 -i $inventory"
opts_adhoc="$opts -e @conf/satperf.yaml -e @$local_conf"


section "Checking environment"
generic_environment_check false false

section "Remote execution"
job_template_ansible_default='Run Command - Ansible Default'
job_template_ssh_default='Run Command - Script Default'

skip_measurement='true' h 10-rex-set-via-ip.log "settings set --name remote_execution_connect_by_ip --value true"
skip_measurement='true' a 11-rex-cleanup-know_hosts.log satellite6 -m "shell" -a "rm -rf /usr/share/foreman-proxy/.ssh/known_hosts*"

skip_measurement='true' h 12-rex-update.log "job-invocation create --async --description-format 'Run %{command} (%{template_name})' --inputs command='dnf -y update' --job-template '$job_template_ssh_default' --search-query 'name ~ container'"
j $logs/12-rex-update.log
s $wait_interval


junit_upload
