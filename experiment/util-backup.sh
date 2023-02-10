#!/bin/bash

source experiment/run-library.sh

inventory="${PARAM_inventory:-conf/contperf/inventory.ini}"
private_key="${PARAM_private_key:-conf/contperf/id_rsa_perf}"
local_conf="${PARAM_local_conf:-conf/satperf.local.yaml}"

wait_interval=${PARAM_wait_interval:-50}

opts="--forks 100 -i $inventory --private-key $private_key"
opts_adhoc="$opts --user root -e @conf/satperf.yaml -e @$local_conf"


section "Backup"
a 00-backup.log satellite6 -m "shell" -a "rm -rf /root/backup /tmp/backup; mkdir /tmp/backup; satellite-maintain backup offline --skip-pulp-content --assumeyes /tmp/backup; mv /tmp/backup /root/"
a 00-hammer-ping.log satellite6 -m "shell" -a "hammer -u {{ sat_user }} -p {{ sat_pass }} ping"


junit_upload
