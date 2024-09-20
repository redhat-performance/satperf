#!/bin/sh

source experiment/run-library.sh

branch="${PARAM_branch:-satcpt}"
inventory="${PARAM_inventory:-conf/contperf/inventory.${branch}.ini}"

dl="Default Location"

opts="--forks 100 -i $inventory"
opts_adhoc="$opts"


section "Checking environment"
generic_environment_check false false
# set +e


section "Remote execution"
job_template_ansible_default='Run Command - Ansible Default'
job_template_ssh_default='Run Command - Script Default'

skip_measurement='true' h 10-rex-set-via-ip.log \
  'settings set --name remote_execution_connect_by_ip --value true'
skip_measurement='true' a 11-rex-cleanup-know_hosts.log \
  -m 'ansible.builtin.shell' \
  -a 'rm -rf /usr/share/foreman-proxy/.ssh/known_hosts*' \
  satellite6

skip_measurement='true' h 17-rex-katello_package_install-podman.log \
  "job-invocation create --async --description-format 'Install %{package} (%{template_name})' --feature katello_package_install --inputs package='podman' --search-query 'name ~ container'"
jsr "$logs/17-rex-katello_package_install-podman.log"
j "$logs/17-rex-katello_package_install-podman.log"

skip_measurement='true' h 17-rex-podman_pull.log \
  "job-invocation create --async --description-format 'Run %{command} (%{template_name})' --inputs command='bash -x /root/podman-pull.sh' --job-template '$job_template_ssh_default' --search-query 'name ~ container'"
jsr "$logs/17-rex-podman_pull.log"
j "$logs/17-rex-podman_pull.log"

skip_measurement='true' h 18-rex-fake_dnf_upgrade.log \
  "job-invocation create --async --description-format 'Run %{command} (%{template_name})' --inputs command='TMPDIR=\"\$(mktemp -d)\" && dnf upgrade -y --downloadonly --destdir=\$TMPDIR && dnf clean all && rm -rf \$TMPDIR' --job-template '$job_template_ssh_default' --search-query 'name ~ container'"
jsr "$logs/18-rex-fake_dnf_upgrade.log"
j "$logs/18-rex-fake_dnf_upgrade.log"


junit_upload
