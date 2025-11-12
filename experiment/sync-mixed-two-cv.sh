#!/bin/bash

source experiment/run-library.sh

test_sync_mixed_count="${PARAM_test_sync_mixed_count:-8}"
test_sync_mixed_max_sync_secs="${PARAM_test_sync_mixed_max_sync_secs:-1200}"
test_sync_docker_url_template="${PARAM_test_sync_docker_url_template:-https://registry-1.docker.io}"
test_sync_repositories_url_template="${PARAM_test_sync_repositories_url_template:-http://repos.example.com/repo*}"
test_sync_iso_url_template="${PARAM_test_sync_iso_url_template:-http://storage.example.com/iso-repos*}"


section 'Checking environment'
generic_environment_check
# unset skip_measurement
# set +e


section "Sync mixed repo"
ap 10-test-sync-mixed.log \
  -e "organization='{{ sat_org }}'" \
  -e "test_sync_mixed_count=$test_sync_mixed_count" \
  -e "test_sync_repositories_url_template=$test_sync_repositories_url_template" \
  -e "test_sync_iso_url_template=$test_sync_iso_url_template" \
  -e "test_sync_docker_url_template=$test_sync_docker_url_template" \
  -e "test_sync_mixed_max_sync_secs=$test_sync_mixed_max_sync_secs" \
  playbooks/tests/sync-mixed-repos-two-cvs.yaml


section "Summary"
e SyncRepositoriesYum $logs/10-test-sync-mixed.log
e SyncRepositoriesDocker $logs/10-test-sync-mixed.log
e SyncRepositoriesISO $logs/10-test-sync-mixed.log
e PublishContentViews $logs/10-test-sync-mixed.log
e PromoteContentViews $logs/10-test-sync-mixed.log


junit_upload
