#!/bin/sh

source experiment/run-library.sh


section 'Checking environment'
# generic_environment_check false false
unset skip_measurement
set +e


section 'Remote execution'
# job_template_ansible_default='Run Command - Ansible Default'
job_template_ssh_default='Run Command - Script Default'

skip_measurement='true' h 10-rex-set-via-ip.log \
  'settings set --name remote_execution_connect_by_ip --value true'
skip_measurement='true' a 11-rex-cleanup-know_hosts.log \
  -m 'ansible.builtin.shell' \
  -a 'rm -rf /usr/share/foreman-proxy/.ssh/known_hosts*' \
  satellite6

test=15-rex-date
skip_measurement=true h "${test}.log" \
  "job-invocation create --async --description-format 'Run %{command} (%{template_name})' --inputs command='date' --job-template '$job_template_ssh_default' --search-query 'name ~ container'"
jsr "${logs}/${test}.log" 15
j "${logs}/${test}.log" &

test=16-rex-dnf_uploadprofile
skip_measurement=true h "${test}.log" \
  "job-invocation create --async --description-format 'Run %{command} (%{template_name})' --inputs command='dnf uploadprofile --force-upload' --job-template '$job_template_ssh_default' --search-query 'name ~ container'"
jsr "${logs}/${test}.log" 15
j "${logs}/${test}.log" &

test=19-rex-sleep_300_uptime
skip_measurement=true h "${test}.log" \
  "job-invocation create --async --description-format 'Run %{command} (%{template_name})' --inputs command='sleep 300; uptime' --job-template '$job_template_ssh_default' --search-query 'name ~ container'"
jsr "${logs}/${test}.log" 30
j "${logs}/${test}.log" &


wait


junit_upload
