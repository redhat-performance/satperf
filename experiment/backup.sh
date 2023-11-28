#!/bin/sh

source experiment/run-library.sh

branch="${PARAM_branch:-satcpt}"
inventory="${PARAM_inventory:-conf/contperf/inventory.${branch}.ini}"

cdn_url_mirror="${PARAM_cdn_url_mirror:-https://cdn.redhat.com/}"

dl="Default Location"

opts="--forks 100 -i $inventory"
opts_adhoc="$opts -e branch='$branch'"


section "BackupTest"
ap 00-backup.log playbooks/tests/sat-backup.yaml
e BackupOffline $logs/00-backup.log
e RestoreOffline $logs/00-backup.log
e BackupOnline $logs/00-backup.log
e RestoreOnline $logs/00-backup.log


junit_upload
