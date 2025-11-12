#!/bin/sh

source experiment/run-library.sh


section 'Checking environment'
generic_environment_check false false
# unset skip_measurement
# set +e


section 'Remote execution'
job_template_ansible_default='Run Command - Ansible Default'
job_template_ssh_default='Run Command - Script Default'

skip_measurement='true' h 10-rex-set-via-ip.log \
  'settings set --name remote_execution_connect_by_ip --value true'
skip_measurement='true' a 11-rex-cleanup-know_hosts.log \
  -m 'ansible.builtin.shell' \
  -a 'rm -rf /usr/share/foreman-proxy/.ssh/known_hosts*' \
  satellite6

skip_measurement='true' h 15-rex-date-ansible.log \
  "job-invocation create --async --description-format 'Run %{command} (%{template_name})' --inputs command='date' --job-template '$job_template_ansible_default' --search-query 'name ~ container'"
jsr "$logs/15-rex-date-ansible.log"
j "$logs/15-rex-date-ansible.log"

skip_measurement='true' h 15-rex-date.log \
  "job-invocation create --async --description-format 'Run %{command} (%{template_name})' --inputs command='date' --job-template '$job_template_ssh_default' --search-query 'name ~ container'"
jsr "$logs/15-rex-date.log"
j "$logs/15-rex-date.log"

skip_measurement='true' h 16-rex-uploadprofile.log \
  "job-invocation create --async --description-format 'Run %{command} (%{template_name})' --inputs command='dnf uploadprofile --force-upload' --job-template '$job_template_ssh_default' --search-query 'name ~ container'"
jsr "$logs/16-rex-uploadprofile.log"
j "$logs/16-rex-uploadprofile.log"

skip_measurement='true' h 17-rex-katello_package_install-podman.log \
  "job-invocation create --async --description-format 'Install %{package} (%{template_name})' --feature katello_package_install --inputs package='podman' --search-query 'name ~ container'"
jsr "$logs/17-rex-katello_package_install-podman.log"
j "$logs/17-rex-katello_package_install-podman.log"

skip_measurement='true' h 17-rex-podman_pull.log \
  "job-invocation create --async --description-format 'Run %{command} (%{template_name})' --inputs command='bash -x /root/podman-pull.sh' --job-template '$job_template_ssh_default' --search-query 'name ~ container'"
jsr "$logs/17-rex-podman_pull.log"
j "$logs/17-rex-podman_pull.log"

skip_measurement='true' h 18-rex-katello_package_update.log \
  "job-invocation create --async --description-format '%{template_name}' --feature katello_package_update --search-query 'name ~ container'"
jsr "$logs/18-rex-katello_package_update.log"
j "$logs/18-rex-katello_package_update.log"


junit_upload
