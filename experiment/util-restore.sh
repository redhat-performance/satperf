#!/bin/bash

source experiment/run-library.sh

inventory="${PARAM_inventory:-conf/contperf/inventory.ini}"
local_conf="${PARAM_local_conf:-conf/satperf.local.yaml}"

wait_interval=${PARAM_wait_interval:-50}

opts="--forks 100 -i $inventory"
opts_adhoc="$opts -e @conf/satperf.yaml -e @$local_conf"


section "Restore"
a 00-backup.log satellite6 -m "shell" -a "rm -rf /tmp/backup; cp -r /root/backup /tmp/; satellite-maintain restore --assumeyes /tmp/backup/*; rm -rf /tmp/backup"
a 00-hammer-ping.log satellite6 -m "shell" -a "hammer -u {{ sat_user }} -p {{ sat_pass }} ping"


junit_upload
