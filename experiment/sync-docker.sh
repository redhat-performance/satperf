#!/bin/bash

source experiment/run-library.sh

branch="${PARAM_branch:-satcpt}"
inventory="${PARAM_inventory:-conf/contperf/inventory.${branch}.ini}"

test_sync_docker_count="${PARAM_test_sync_docker_count:-8}"
test_sync_docker_url_template="${PARAM_test_sync_docker_url_template:-https://registry-1.docker.io}"
test_sync_docker_max_sync_secs="${PARAM_test_sync_docker_max_sync_secs:-600}"

opts="--forks 100 -i $inventory"
opts_adhoc="$opts"


#section "Checking environment"
#generic_environment_check false


section "Sync docker repo"
ap 10-test-sync-docker.log \
  -e "organization='{{ sat_org }}'" \
  -e "test_sync_docker_count=$test_sync_docker_count" \
  -e "test_sync_docker_url_template=$test_sync_docker_url_template" \
  -e "test_sync_docker_max_sync_secs=$test_sync_docker_max_sync_secs" \
  playbooks/tests/sync-docker.yaml


section "Summary"
e SyncRepositories $logs/10-test-sync-docker.log
e PublishContentViews $logs/10-test-sync-docker.log
e PromoteContentViews $logs/10-test-sync-docker.log


section "Sosreport"
skip_measurement='true' ap sosreporter-gatherer.log \
   -e "sosreport_gatherer_local_dir='../../$logs/sosreport/'" \
  playbooks/satellite/sosreport_gatherer.yaml

junit_upload
