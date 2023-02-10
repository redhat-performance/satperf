#!/bin/bash

source experiment/run-library.sh

organization="${PARAM_organization:-Default Organization}"
manifest="${PARAM_manifest:-conf/contperf/manifest_SCA.zip}"
inventory="${PARAM_inventory:-conf/contperf/inventory.ini}"
private_key="${PARAM_private_key:-conf/contperf/id_rsa_perf}"
local_conf="${PARAM_local_conf:-conf/satperf.local.yaml}"

test_sync_repositories_count="${PARAM_test_sync_repositories_count:-8}"
test_sync_repositories_url_template="${PARAM_test_sync_repositories_url_template:-http://repos.example.com/repo*}"
test_sync_repositories_max_sync_secs="${PARAM_test_sync_repositories_max_sync_secs:-600}"

test_sync_iso_count="${PARAM_test_sync_iso_count:-8}"
test_sync_iso_url_template="${PARAM_test_sync_iso_url_template:-http://storage.example.com/iso-repos*}"
test_sync_iso_max_sync_secs="${PARAM_test_sync_iso_max_sync_secs:-600}"

test_sync_docker_count="${PARAM_test_sync_docker_count:-8}"
test_sync_docker_url_template="${PARAM_test_sync_docker_url_template:-https://registry-1.docker.io}"
test_sync_docker_max_sync_secs="${PARAM_test_sync_docker_max_sync_secs:-600}"

wait_interval=${PARAM_wait_interval:-50}

cdn_url_mirror="${PARAM_cdn_url_mirror:-https://cdn.redhat.com/}"
cdn_url_full="${PARAM_cdn_url_full:-https://cdn.redhat.com/}"

dl="Default Location"

opts="--forks 100 -i $inventory --private-key $private_key"
opts_adhoc="$opts -e @conf/satperf.yaml -e @$local_conf"


section "Checking environment"
generic_environment_check false

section "Sync test"
# Yum repositories
ap 10-test-sync-repositories.log playbooks/tests/sync-repositories.yaml -e "test_sync_repositories_count=$test_sync_repositories_count test_sync_repositories_url_template=$test_sync_repositories_url_template test_sync_repositories_max_sync_secs=$test_sync_repositories_max_sync_secs"
# ISO repositories
ap 10-test-sync-iso.log playbooks/tests/sync-iso.yaml -e "test_sync_iso_count=$test_sync_iso_count test_sync_iso_url_template=$test_sync_iso_url_template test_sync_iso_max_sync_secs=$test_sync_iso_max_sync_secs"
# Container repositories
ap 10-test-sync-docker.log playbooks/tests/sync-docker.yaml -e "test_sync_docker_count=$test_sync_docker_count test_sync_docker_url_template=$test_sync_docker_url_template test_sync_docker_max_sync_secs=$test_sync_docker_max_sync_secs"

section "Summary"
# Yum repositories
e SyncRepositories $logs/10-test-sync-repositories.log
e PublishContentViews $logs/10-test-sync-repositories.log
e PromoteContentViews $logs/10-test-sync-repositories.log
# ISO repositories
e SyncRepositories $logs/10-test-sync-iso.log
e PublishContentViews $logs/10-test-sync-iso.log
e PromoteContentViews $logs/10-test-sync-iso.log
# Container repositories
e SyncRepositories $logs/10-test-sync-docker.log
e PublishContentViews $logs/10-test-sync-docker.log
e PromoteContentViews $logs/10-test-sync-docker.log

section "Sosreport"
skip_measurement='true' ap sosreporter-gatherer.log playbooks/satellite/sosreport_gatherer.yaml -e "sosreport_gatherer_local_dir='../../$logs/sosreport/'"

junit_upload
