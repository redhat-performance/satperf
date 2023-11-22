#!/bin/bash

source experiment/run-library.sh

branch="${PARAM_branch:-satcpt}"
inventory="${PARAM_inventory:-conf/contperf/inventory.${branch}.ini}"

wait_interval=${PARAM_wait_interval:-50}

opts="--forks 100 -i $inventory"
opts_adhoc="$opts -e branch='$branch'"


section "Backup"
a 00-backup.log satellite6 -m "shell" -a "rm -rf /root/backup /tmp/backup; mkdir /tmp/backup; satellite-maintain backup offline --skip-pulp-content --assumeyes /tmp/backup; mv /tmp/backup /root/"
a 00-hammer-ping.log satellite6 -m "shell" -a "hammer -u {{ sat_user }} -p {{ sat_pass }} ping"


junit_upload
