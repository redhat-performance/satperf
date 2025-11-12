#!/bin/bash

source experiment/run-library.sh

test_sync_ansible_collections_count="${PARAM_test_sync_ansible_collections_count:-8}"
test_sync_ansible_collections_url_template="${PARAM_test_sync_ansible_collections_url_template:-https://galaxy.ansible.com/}"
test_sync_ansible_collections_max_sync_secs="${PARAM_test_sync_ansible_collections_max_sync_secs:-600}"


section 'Checking environment'
generic_environment_check false false
# unset skip_measurement
# set +e


section "Sync test"
ap 10-test-sync-ansible-collections.log \
  -e "organization='{{ sat_org }}'" \
  -e "test_sync_ansible_collections_count=$test_sync_ansible_collections_count" \
  -e "test_sync_ansible_collections_url_template=$test_sync_ansible_collections_url_template" \
  -e "test_sync_ansible_collections_max_sync_secs=$test_sync_ansible_collections_max_sync_secs" \
  playbooks/tests/sync-ansible-collections.yaml


section "Summary"
e SyncRepositories $logs/10-test-sync-ansible-collections.log
e PublishContentViews $logs/10-test-sync-ansible-collections.log
e PromoteContentViews $logs/10-test-sync-ansible-collections.log


section "Sosreport"
skip_measurement='true' ap sosreporter-gatherer.log \
  -e "sosreport_gatherer_local_dir='../../$logs/sosreport/'" \
  playbooks/satellite/sosreport_gatherer.yaml


junit_upload
