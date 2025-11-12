#!/bin/bash

source experiment/run-library.sh

test_sync_repositories_count="${PARAM_test_sync_repositories_count:-8}"
test_sync_repositories_url_template="${PARAM_test_sync_repositories_url_template:-http://repos.example.com/repo*}"
test_sync_repositories_max_sync_secs="${PARAM_test_sync_repositories_max_sync_secs:-600}"


section 'Checking environment'
generic_environment_check false true
# unset skip_measurement
# set +e


section "Sync test"
ap 10-test-sync-repositories.log \
  -e "organization='{{ sat_org }}'" \
  -e "test_sync_repositories_count=$test_sync_repositories_count" \
  -e "test_sync_repositories_url_template=$test_sync_repositories_url_template" \
  -e "test_sync_repositories_max_sync_secs=$test_sync_repositories_max_sync_secs" \
  playbooks/tests/sync-repositories.yaml


section "Summary"
e SyncRepositories $logs/10-test-sync-repositories.log
e PublishContentViews $logs/10-test-sync-repositories.log
e PromoteContentViews $logs/10-test-sync-repositories.log


section "Sosreport"
skip_measurement='true' ap sosreporter-gatherer.log \
  -e "sosreport_gatherer_local_dir='../../$logs/sosreport/'" \
  playbooks/satellite/sosreport_gatherer.yaml


junit_upload
