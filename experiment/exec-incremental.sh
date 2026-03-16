#!/bin/bash

source experiment/run-library.sh

script="${PARAM_script:-insights-client}"


section 'Checking environment'
# generic_environment_check false false
unset skip_measurement
set +e


section 'Incremental concurrent script execution'
num_containers_per_container_host="$( get_inventory_var containers_count container_hosts[0] )"
min_containers_per_batch=4
initial_concurrent_per_container_host=$min_containers_per_batch
prefix=50-exec

for (( batch=1, remaining_containers_per_container_host=num_containers_per_container_host, total_executed=0; remaining_containers_per_container_host > 0; batch++ )); do
    if (( remaining_containers_per_container_host > initial_concurrent_per_container_host * batch )); then
        concurrent_per_container_host="$(( initial_concurrent_per_container_host * batch ))"
    else
        concurrent_per_container_host=$remaining_containers_per_container_host
    fi
    concurrent_total="$(( concurrent_per_container_host * num_container_hosts ))"
    (( remaining_containers_per_container_host -= concurrent_per_container_host ))
    (( total_executed += concurrent_total ))

    log "Running '$script' on $concurrent_total content hosts concurrently in this batch"

    test="${prefix}-${concurrent_total}"
    ap "${test}.log" \
      -e "size='$concurrent_per_container_host'" \
      -e "script='$script'" \
      -e "execution_logs='../../$logs/$prefix-container-host-client-logs'" \
      -e "profile='$profiling_enabled'" \
      -e "execution_profile_img='$test.svg'" \
      playbooks/tests/concurrent_execution.yaml
    e Execute "${logs}/${test}.log"
done
grep Execute "$logs"/$prefix-*.log >"$logs/$prefix-overall.log"
e Execute "$logs/$prefix-overall.log"


section 'Sosreport'
skip_measurement='true' ap sosreporter-gatherer.log \
  -e "sosreport_gatherer_local_dir='../../$logs/sosreport/'" \
  playbooks/satellite/sosreport_gatherer.yaml


junit_upload
