#!/bin/sh

source experiment/run-library.sh


section "BackupTest"
ap 00-backup-skip-pulp.log playbooks/tests/sat-backup.yaml
e BackupOfflineSkipPulp $logs/00-backup-skip-pulp.log
e RestoreOfflineSkipPulp $logs/00-backup-skip-pulp.log
if [[ "${deployment_method:-rpm}" == 'rpm' ]]; then
    e BackupOnlineSkipPulp $logs/00-backup-skip-pulp.log
    e RestoreOnlineSkipPulp $logs/00-backup-skip-pulp.log
fi


junit_upload
