#!/bin/sh

source experiment/run-library.sh

branch="${PARAM_branch:-satcpt}"
inventory="${PARAM_inventory:-conf/contperf/inventory.${branch}.ini}"

dl="Default Location"

opts="--forks 100 -i $inventory"
opts_adhoc="$opts -e branch='$branch'"


section "Checking environment"
generic_environment_check false false

section "Remote execution"
job_template_ansible_default='Run Command - Ansible Default'
job_template_ssh_default='Run Command - Script Default'

skip_measurement='true' h 10-rex-set-via-ip.log "settings set --name remote_execution_connect_by_ip --value true"
skip_measurement='true' a 11-rex-cleanup-know_hosts.log satellite6 -m "shell" -a "rm -rf /usr/share/foreman-proxy/.ssh/known_hosts*"

skip_measurement='true' h 12-rex-date.log "job-invocation create --async --description-format 'Run %{command} (%{template_name})' --inputs command='date' --job-template '$job_template_ssh_default' --search-query 'name ~ container'"
j $logs/12-rex-date.log
skip_measurement='true' h 12-rex-date-ansible.log "job-invocation create --async --description-format 'Run %{command} (%{template_name})' --inputs command='date' --job-template '$job_template_ansible_default' --search-query 'name ~ container'"
j $logs/12-rex-date-ansible.log
skip_measurement='true' h 13-rex-sm-facts-update.log "job-invocation create --async --description-format 'Run %{command} (%{template_name})' --inputs command='subscription-manager facts --update' --job-template '$job_template_ssh_default' --search-query 'name ~ container'"
j $logs/13-rex-sm-facts-update.log
skip_measurement='true' h 14-rex-uploadprofile.log "job-invocation create --async --description-format 'Run %{command} (%{template_name})' --inputs command='dnf uploadprofile --force-upload' --job-template '$job_template_ssh_default' --search-query 'name ~ container'"
j $logs/14-rex-uploadprofile.log

junit_upload
