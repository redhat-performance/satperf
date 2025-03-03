#!/bin/sh

source experiment/run-library.sh

branch="${PARAM_branch:-satcpt}"
inventory="${PARAM_inventory:-conf/contperf/inventory.${branch}.ini}"

opts="--forks 100 -i $inventory"
opts_adhoc="$opts"


section 'Checking environment'
generic_environment_check false false
# set +e


section 'Remote execution'
job_template_ssh_default='Run Command - Script Default'

skip_measurement=true h 10-rex-set-via-ip.log \
  'settings set --name remote_execution_connect_by_ip --value true'
skip_measurement=true a 11-rex-cleanup-know_hosts.log \
  -m ansible.builtin.shell \
  -a 'rm -rf /usr/share/foreman-proxy/.ssh/known_hosts*' \
  satellite6

# Satellite
num_matching_rex_hosts="$(h_out "--no-headers --csv host list --organization '{{ sat_org }}' --thin true --search 'name ~ u-hq and name ~ container22'" | grep -c 'container')"
skip_measurement=true h 50-rex-insigths-client_satellite_${num_matching_rex_hosts}.log \
  "job-invocation create --async --description-format '${num_matching_rex_hosts} hosts - Run %{command} (%{template_name})' --search-query 'name ~ u-hq and name ~ container22' --inputs command='insights-client' --job-template '$job_template_ssh_default'"
jsr "$logs/50-rex-insigths-client_satellite_${num_matching_rex_hosts}.log"
j "$logs/50-rex-insigths-client_satellite_${num_matching_rex_hosts}.log"

num_matching_rex_hosts="$(h_out "--no-headers --csv host list --organization '{{ sat_org }}' --thin true --search 'name ~ u-hq and name ~ container1'" | grep -c 'container')"
skip_measurement=true h 50-rex-insigths-client_satellite_${num_matching_rex_hosts}.log \
  "job-invocation create --async --description-format '${num_matching_rex_hosts} hosts - Run %{command} (%{template_name})' --search-query 'name ~ u-hq and name ~ container1' --inputs command='insights-client' --job-template '$job_template_ssh_default'"
jsr "$logs/50-rex-insigths-client_satellite_${num_matching_rex_hosts}.log"
j "$logs/50-rex-insigths-client_satellite_${num_matching_rex_hosts}.log"

num_matching_rex_hosts="$(h_out "--no-headers --csv host list --organization '{{ sat_org }}' --thin true --search 'name ~ u-hq and name ~ container'" | grep -c 'container')"
skip_measurement=true h 50-rex-insigths-client_satellite_${num_matching_rex_hosts}.log \
  "job-invocation create --async --description-format '${num_matching_rex_hosts} hosts - Run %{command} (%{template_name})' --search-query 'name ~ u-hq and name ~ container' --inputs command='insights-client' --job-template '$job_template_ssh_default'"
jsr "$logs/50-rex-insigths-client_satellite_${num_matching_rex_hosts}.log"
j "$logs/50-rex-insigths-client_satellite_${num_matching_rex_hosts}.log"

# Satellite + capsules
num_matching_rex_hosts="$(h_out "--no-headers --csv host list --organization '{{ sat_org }}' --thin true --search 'name ~ container22'" | grep -c 'container')"
skip_measurement=true h 50-rex-insigths-client_satellite-capsules_${num_matching_rex_hosts}.log \
  "job-invocation create --async --description-format '${num_matching_rex_hosts} hosts - Run %{command} (%{template_name})' --search-query 'name ~ container22' --inputs command='insights-client' --job-template '$job_template_ssh_default'"
jsr "$logs/50-rex-insigths-client_satellite-capsules_${num_matching_rex_hosts}.log"
j "$logs/50-rex-insigths-client_satellite-capsules_${num_matching_rex_hosts}.log"

num_matching_rex_hosts="$(h_out "--no-headers --csv host list --organization '{{ sat_org }}' --thin true --search 'name ~ container1'" | grep -c 'container')"
skip_measurement=true h 50-rex-insigths-client_satellite-capsules_${num_matching_rex_hosts}.log \
  "job-invocation create --async --description-format '${num_matching_rex_hosts} hosts - Run %{command} (%{template_name})' --search-query 'name ~ container1' --inputs command='insights-client' --job-template '$job_template_ssh_default'"
jsr "$logs/50-rex-insigths-client_satellite-capsules_${num_matching_rex_hosts}.log"
j "$logs/50-rex-insigths-client_satellite-capsules_${num_matching_rex_hosts}.log"

num_matching_rex_hosts="$(h_out "--no-headers --csv host list --organization '{{ sat_org }}' --thin true --search 'name ~ container'" | grep -c 'container')"
skip_measurement=true h 50-rex-insigths-client_satellite-capsules_${num_matching_rex_hosts}.log \
  "job-invocation create --async --description-format '${num_matching_rex_hosts} hosts - Run %{command} (%{template_name})' --search-query 'name ~ container' --inputs command='insights-client' --job-template '$job_template_ssh_default'"
jsr "$logs/50-rex-insigths-client_satellite-capsules_${num_matching_rex_hosts}.log"
j "$logs/50-rex-insigths-client_satellite-capsules_${num_matching_rex_hosts}.log"


section 'Sosreport'
skip_measurement=true ap sosreporter-gatherer.log \
  -e "sosreport_gatherer_local_dir='../../$logs/sosreport/'" \
  playbooks/satellite/sosreport_gatherer.yaml


junit_upload
