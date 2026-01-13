#!/bin/bash

source experiment/run-library.sh

lces="${PARAM_lces:-Test}"

rels="${PARAM_rels:-rhel8 rhel9 rhel10}"


section 'Checking environment'
generic_environment_check
# unset skip_measurement
# set +e


section 'Prepare for registrations'
unset aks
for rel in $rels; do
    rel_num="${rel##rhel}"

    for lce in $lces; do
        ak="AK_${rel_num}_${lce}"
        aks+=" $ak"
    done
done

# XXX: FAM: theforeman.foreman.registration_command
ap 44-generate-host-registration-commands.log \
  -e "organization='{{ sat_org }}'" \
  -e "aks='$aks'" \
  -e "sat_version='$sat_version'" \
  -e "enable_iop='$enable_iop'" \
  playbooks/satellite/host-registration_generate-commands.yaml

ap 44-recreate-client-scripts.log \
  -e "aks='$aks'" \
  -e "sat_version='$sat_version'" \
  playbooks/satellite/client-scripts.yaml


section 'Incremental registrations'
num_containers_per_container_host="$( get_inventory_var containers_count container_hosts[0] )"
min_containers_per_batch=4
initial_concurrent_registrations_per_container_host=$min_containers_per_batch
num_retry_forks=$min_containers_per_batch
prefix=48-register

for (( batch=1, remaining_containers_per_container_host=num_containers_per_container_host, total_registered=0; remaining_containers_per_container_host > 0; batch++ )); do
    if (( remaining_containers_per_container_host > initial_concurrent_registrations_per_container_host * batch )); then
        concurrent_registrations_per_container_host="$(( initial_concurrent_registrations_per_container_host * batch ))"
    else
        concurrent_registrations_per_container_host=$remaining_containers_per_container_host
    fi
    concurrent_registrations="$(( concurrent_registrations_per_container_host * num_container_hosts ))"
    (( remaining_containers_per_container_host -= concurrent_registrations_per_container_host ))
    (( total_registered += concurrent_registrations ))

    log "Trying to register $concurrent_registrations content hosts concurrently in this batch"

    test="${prefix}-${concurrent_registrations}"
    ap "${test}.log" \
      -e "size='$concurrent_registrations_per_container_host'" \
      -e "concurrent_registrations='$concurrent_registrations'" \
      -e "num_retry_forks='$num_retry_forks'" \
      -e "registration_logs='../../$logs/$prefix-container-host-client-logs'" \
      -e 're_register_failed_hosts=true' \
      -e "sat_version='$sat_version'" \
      -e "profile='$profiling_enabled'" \
      -e "registration_profile_img='$test.svg'" \
      playbooks/tests/registrations.yaml
    e Register "${logs}/${test}.log"
done
grep Register "$logs"/$prefix-*.log >"$logs/$prefix-overall.log"
e Register "$logs/$prefix-overall.log"


section 'Sosreport'
skip_measurement='true' ap sosreporter-gatherer.log \
  -e "sosreport_gatherer_local_dir='../../$logs/sosreport/'" \
  playbooks/satellite/sosreport_gatherer.yaml


junit_upload
