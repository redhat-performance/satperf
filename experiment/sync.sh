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
a regs-00-info-rpm-qa.log satellite6 -m "shell" -a "rpm -qa | sort"
a regs-00-info-hostname.log satellite6 -m "shell" -a "hostname"
a regs-00-check-ping-sat.log docker-hosts -m "shell" -a "ping -c 3 {{ groups['satellite6']|first }}"
a regs-00-check-hammer-ping.log satellite6 -m "shell" -a "! ( hammer $hammer_opts ping | grep 'Status:' | grep -v 'ok$' )"
ap regs-00-recreate-containers.log playbooks/docker/docker-tierdown.yaml playbooks/docker/docker-tierup.yaml
ap regs-00-recreate-client-scripts.log playbooks/satellite/client-scripts.yaml
ap regs-00-remove-hosts-if-any.log playbooks/satellite/satellite-remove-hosts.yaml
a regs-00-satellite-drop-caches.log -m shell -a "katello-service stop; sync; echo 3 > /proc/sys/vm/drop_caches; katello-service start" satellite6
a regs-00-info-rpm-q-satellite.log satellite6 -m "shell" -a "rpm -q satellite"
satellite_version=$( tail -n 1 $logs/regs-00-info-rpm-q-satellite.log ); echo "$satellite_version" | grep '^satellite-6\.'   # make sure it was detected correctly
s $( expr 3 \* $wait_interval )
set +e

section "Sync test"
ap 10-test-sync-repositories.log playbooks/tests/sync-repositories.yaml -e "test_sync_repositories_count=$test_sync_repositories_count test_sync_repositories_url_template=$test_sync_repositories_url_template test_sync_repositories_max_sync_secs=$test_sync_repositories_max_sync_secs"

section "Summary"
log "$( experiment/reg-average.sh SyncRepositories $logs/10-test-sync-repositories.log | tail -n 1 )"
log "$( experiment/reg-average.sh PublishContentViews $logs/10-test-sync-repositories.log | tail -n 1 )"
log "$( experiment/reg-average.sh PromoteContentViews $logs/10-test-sync-repositories.log | tail -n 1 )"

junit_upload
