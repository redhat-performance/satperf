#!/bin/bash

source experiment/run-library.sh

inventory="${PARAM_inventory:-conf/contperf/inventory.ini}"
private_key="${PARAM_private_key:-conf/contperf/id_rsa_perf}"

wait_interval=${PARAM_wait_interval:-50}

opts="--forks 100 -i $inventory --private-key $private_key"
opts_adhoc="$opts --user root -e @conf/satperf.yaml -e @conf/satperf.local.yaml"


section "Restore"
a 00-backup.log satellite6 -m "shell" -a "rm -rf /tmp/backup; cp -r /root/backup /tmp/; satellite-maintain restore --assumeyes /tmp/backup/*; rm -rf /tmp/backup"
a 00-hammer-ping.log satellite6 -m "shell" -a "hammer -u {{ sat_user }} -p {{ sat_pass }} ping"
