#!/bin/sh

source experiment/run-library.sh

branch="${PARAM_branch:-satcpt}"
inventory="${PARAM_inventory:-conf/contperf/inventory.${branch}.ini}"

dl="Default Location"

opts="--forks 100 -i $inventory"
opts_adhoc="$opts"


section "Checking environment"
generic_environment_check false false


section "Remote execution"
job_template_ansible_default='Run Command - Ansible Default'
job_template_ssh_default='Run Command - Script Default'

skip_measurement='true' h 10-rex-set-via-ip.log "settings set --name remote_execution_connect_by_ip --value true"
skip_measurement='true' a 11-rex-cleanup-know_hosts.log \
  -m "ansible.builtin.shell" \
  -a "rm -rf /usr/share/foreman-proxy/.ssh/known_hosts*" \
  satellite6

skip_measurement='true' h 12-rex-date-ansible.log "job-invocation create --async --description-format 'Run %{command} (%{template_name})' --inputs command='date' --job-template '$job_template_ansible_default' --search-query 'name ~ container'"
jsr $logs/12-rex-date-ansible.log
j $logs/12-rex-date-ansible.log

skip_measurement='true' h 12-rex-date.log "job-invocation create --async --description-format 'Run %{command} (%{template_name})' --inputs command='date' --job-template '$job_template_ssh_default' --search-query 'name ~ container'"
jsr $logs/12-rex-date.log
j $logs/12-rex-date.log

skip_measurement='true' h 14-rex-uploadprofile.log "job-invocation create --async --description-format 'Run %{command} (%{template_name})' --inputs command='dnf uploadprofile --force-upload' --job-template '$job_template_ssh_default' --search-query 'name ~ container'"
jsr $logs/14-rex-uploadprofile.log
j $logs/14-rex-uploadprofile.log

skip_measurement='true' h 15-rex-katello_package_update.log "job-invocation create --async --description-format '%{template_name}' --feature katello_package_update --search-query 'name ~ container'"
jsr $logs/15-rex-katello_package_update.log
j $logs/15-rex-katello_package_update.log


junit_upload
