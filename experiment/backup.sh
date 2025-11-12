#!/bin/sh

source experiment/run-library.sh


section "BackupTest"
ap 00-backup.log playbooks/tests/sat-backup.yaml
e BackupOffline $logs/00-backup.log
e RestoreOffline $logs/00-backup.log
e BackupOnline $logs/00-backup.log
e RestoreOnline $logs/00-backup.log


junit_upload
