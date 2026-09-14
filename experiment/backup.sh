#!/bin/sh

source experiment/run-library.sh


section "BackupTest"
ap 00-backup-skip-pulp.log playbooks/tests/sat-backup.yaml
e BackupOfflineSkipPulpSatellite $logs/00-backup-skip-pulp.log
e RestoreOfflineSkipPulpSatellite $logs/00-backup-skip-pulp.log
num_capsules="${num_capsules:-$(get_num_hosts capsules)}"
if (( num_capsules > 0 )); then
    e BackupOfflineSkipPulpCapsule $logs/00-backup-skip-pulp.log
    e RestoreOfflineSkipPulpCapsule $logs/00-backup-skip-pulp.log
fi
if [[ "${deployment_method:-rpm}" == 'rpm' ]]; then
    e BackupOnlineSkipPulpSatellite $logs/00-backup-skip-pulp.log
    e RestoreOnlineSkipPulpSatellite $logs/00-backup-skip-pulp.log
    if (( num_capsules > 0 )); then
        e BackupOnlineSkipPulpCapsule $logs/00-backup-skip-pulp.log
        e RestoreOnlineSkipPulpCapsule $logs/00-backup-skip-pulp.log
    fi
fi


junit_upload
