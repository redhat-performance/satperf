#!/bin/bash

source experiment/run-library.sh


section "Backup"
a 00-backup.log satellite6 -m "shell" -a "rm -rf /root/backup /tmp/backup; mkdir /tmp/backup; satellite-maintain backup offline --skip-pulp-content --assumeyes /tmp/backup; mv /tmp/backup /root/"
a 00-hammer-ping.log satellite6 -m "shell" -a "hammer -u {{ sat_user }} -p {{ sat_pass }} ping"


junit_upload
