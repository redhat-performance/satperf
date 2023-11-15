#!/bin/sh

source experiment/run-library.sh

organization="${PARAM_organization:-Default Organization}"
manifest="${PARAM_manifest:-conf/contperf/manifest_SCA.zip}"
inventory="${PARAM_inventory:-conf/contperf/inventory.ini}"
local_conf="${PARAM_local_conf:-conf/satperf.local.yaml}"

wait_interval=${PARAM_wait_interval:-50}

cdn_url_mirror="${PARAM_cdn_url_mirror:-https://cdn.redhat.com/}"

dl="Default Location"

opts="--forks 100 -i $inventory"
opts_adhoc="$opts -e @conf/satperf.yaml -e @$local_conf"


section "BackupTest"
ap 00-backup.log playbooks/tests/sat-backup.yaml
e BackupOffline $logs/00-backup.log
e RestoreOffline $logs/00-backup.log
e BackupOnline $logs/00-backup.log
e RestoreOnline $logs/00-backup.log


junit_upload
