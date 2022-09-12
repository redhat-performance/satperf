#!/bin/bash

source experiment/run-library.sh

manifest="${PARAM_manifest:-conf/contperf/manifest.zip}"
inventory="${PARAM_inventory:-conf/contperf/inventory.ini}"
private_key="${PARAM_private_key:-conf/contperf/id_rsa_perf}"

test_sync_iso_count="${PARAM_test_sync_iso_count:-8}"
test_sync_iso_url_template="${PARAM_test_sync_iso_url_template:-http://storage.example.com/iso-repos*}"
test_sync_iso_max_sync_secs="${PARAM_test_sync_iso_max_sync_secs:-600}"

wait_interval=${PARAM_wait_interval:-50}

cdn_url_mirror="${PARAM_cdn_url_mirror:-https://cdn.redhat.com/}"
cdn_url_full="${PARAM_cdn_url_full:-https://cdn.redhat.com/}"

do="Default Organization"
dl="Default Location"

opts="--forks 100 -i $inventory --private-key $private_key"
opts_adhoc="$opts --user root -e @conf/satperf.yaml -e @conf/satperf.local.yaml"

section "Checking environment"
generic_environment_check false

section "Sync file repo"
ap 10-test-sync-iso.log playbooks/tests/sync-iso.yaml -e "test_sync_iso_count=$test_sync_iso_count test_sync_iso_url_template=$test_sync_iso_url_template test_sync_iso_max_sync_secs=$test_sync_iso_max_sync_secs"

section "Summary"
e SyncRepositories $logs/10-test-sync-iso.log
e PublishContentViews $logs/10-test-sync-iso.log
e PromoteContentViews $logs/10-test-sync-iso.log

section "Sosreport"
skip_measurement='true' ap sosreporter-gatherer.log playbooks/satellite/sosreport_gatherer.yaml -e "sosreport_gatherer_local_dir='../../$logs/sosreport/'"

junit_upload
