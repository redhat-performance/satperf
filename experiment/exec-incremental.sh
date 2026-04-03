#!/bin/bash

source experiment/run-library.sh

tasks_list="${PARAM_tasks_list:-registration insights-client subscription-manager_refresh container_pull}"
if vercmp_ge "$sat_version" '6.17.0'; then
    tasks_list="${tasks_list:+$tasks_list }flatpak_install"
fi


section 'Checking environment'
# generic_environment_check false false
unset skip_measurement
set +e


section 'Incremental concurrent script execution'
# Clean up logs from previous runs
skip_measurement=true a 49-cleanup-container-host-logs.log \
  -m ansible.builtin.shell \
  -a 'rm -f /root/out_*.log' \
  container_hosts


num_containers_per_container_host="$( get_inventory_var containers_count container_hosts[0] )"
min_containers_per_batch=4
initial_concurrent_per_container_host=$min_containers_per_batch
prefix=50-concurrent-exec

for (( batch=1, remaining_containers_per_container_host=num_containers_per_container_host, total_executed=0; remaining_containers_per_container_host > 0; batch++ )); do
    if (( remaining_containers_per_container_host > initial_concurrent_per_container_host * batch )); then
        concurrent_per_container_host=$(( initial_concurrent_per_container_host * batch ))
    else
        concurrent_per_container_host=$remaining_containers_per_container_host
    fi
    concurrent_total=$(( concurrent_per_container_host * num_container_hosts ))
    (( remaining_containers_per_container_host -= concurrent_per_container_host ))
    (( total_executed += concurrent_total ))

    log "Running '$tasks_list' on $concurrent_total content hosts concurrently in this batch"

    test="$prefix-$concurrent_total"
    ap "$test.log" \
      -e "size=$concurrent_per_container_host" \
      -e "concurrent_total=$concurrent_total" \
      -e "tasks_list='$tasks_list'" \
      -e "sat_version='$sat_version'" \
      -e "enable_iop=$enable_iop" \
      -e 'retry_failed=true' \
      -e "execution_logs='../../$logs/$prefix-container-host-client-logs'" \
      -e "profile=$profiling_enabled" \
      playbooks/tests/concurrent_tasks.yaml
    for task in $tasks_list; do
        e "Execute $task" "$logs/$test.log"
    done
done

for task in $tasks_list; do
    grep "Execute $task" "$logs"/$prefix-*.log >"$logs/$prefix-$task-overall.log"
    e "Execute $task" "$logs/$prefix-$task-overall.log"
done


section 'Sosreport'
skip_measurement='true' ap sosreporter-gatherer.log \
  -e "sosreport_gatherer_local_dir='../../$logs/sosreport/'" \
  playbooks/satellite/sosreport_gatherer.yaml


junit_upload
