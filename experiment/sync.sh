#!/bin/bash

source experiment/run-library.sh

manifest="${PARAM_manifest:-conf/contperf/manifest.zip}"
inventory="${PARAM_inventory:-conf/contperf/inventory.ini}"
private_key="${PARAM_private_key:-conf/contperf/id_rsa_perf}"

test_sync_repositories_count="${PARAM_test_sync_repositories_count:-8}"
test_sync_repositories_url_template="${PARAM_test_sync_repositories_url_template:-http://repos.example.com/repo*}"
test_sync_repositories_max_sync_secs="${PARAM_test_sync_repositories_max_sync_secs:-600}"

wait_interval=${PARAM_wait_interval:-50}
registrations_batches="${PARAM_registrations_batches:-1 2 3}"

cdn_url_full="${PARAM_cdn_url_full:-https://cdn.redhat.com/}"

repo_sat_tools="${PARAM_repo_sat_tools:-http://mirror.example.com/Satellite_Tools_x86_64/}"

do="Default Organization"
dl="Default Location"

opts="--forks 100 -i $inventory --private-key $private_key"
opts_adhoc="$opts --user root"


section "Checking environment"
generic_environment_check

section "Sync test"
ap 10-test-sync-repositories.log playbooks/tests/sync-repositories.yaml -e "test_sync_repositories_count=$test_sync_repositories_count test_sync_repositories_url_template=$test_sync_repositories_url_template test_sync_repositories_max_sync_secs=$test_sync_repositories_max_sync_secs"

section "Summary"
e SyncRepositories $logs/10-test-sync-repositories.log
e PublishContentViews $logs/10-test-sync-repositories.log
e PromoteContentViews $logs/10-test-sync-repositories.log

junit_upload
