#!/bin/bash

source experiment/run-library.sh

inventory="${PARAM_inventory:-conf/contperf/inventory.ini}"

expected_concurrent_registrations=${PARAM_expected_concurrent_registrations:-125}

opts="--forks 100 -i $inventory"
opts_adhoc="$opts"


section "Checking environment"
generic_environment_check


section "Register"
number_container_hosts="$( ansible -i $inventory --list-hosts container_hosts 2>/dev/null | grep '^  hosts' | sed 's/^  hosts (\([0-9]\+\)):$/\1/' )"
number_containers_per_container_host="$( ansible -i $inventory -m debug -a "var=containers_count" container_hosts[0] | awk '/    "containers_count":/ {print $NF}' )"
total_number_containers="$(( number_container_hosts * number_containers_per_container_host ))"
needed_concurrent_registrations_per_container_host="$(( ( expected_concurrent_registrations + number_container_hosts -1 ) / number_container_hosts ))" # We want ceiling rounding: Ceiling( X / Y ) = ( X + Y – 1 ) / Y
real_concurrent_registrations="$(( needed_concurrent_registrations_per_container_host * number_container_hosts ))"

log "Going to register $real_concurrent_registrations contents hosts"

skip_measurement='true' ap register-00-$real_concurrent_registrations.log \
  -e "size='${needed_concurrent_registrations_per_container_host}'" \
  -e "registration_logs='../../$logs/register-00-container-host-client-logs'" \
  playbooks/tests/registrations.yaml
e Register $logs/register-00-$real_concurrent_registrations.log


section "Sosreport"
ap sosreporter-gatherer.log \
  -e "sosreport_gatherer_local_dir='../../$logs/sosreport/'" \
  playbooks/satellite/sosreport_gatherer.yaml


junit_upload
