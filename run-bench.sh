#!/bin/sh

manifest="/home/pok/DownloadsWork/manifest_ed59abc3-32d7-45fe-bcaf-0160e588a0a6.zip"
do="Default Organization"
logs="logs-$( date --iso-8601=seconds )"
mkdir "$logs/"

opts="--forks 100 -i conf/20180112-scale-meltdown-spectre.ini"
opts_adhoc="$opts --user root"

function log() {
    echo "[$( date --iso-8601=seconds )] $*"
}

function a() {
    local out=$1; shift
    local start=$( date +%s )
    log "Start 'ansible $opts_adhoc $*' with log in $out"
    ansible $opts_adhoc "$@" &>$out
    rc=$?
    local end=$( date +%s )
    log "Finish after $( expr $end - $start ) seconds with exit code $rc"
    echo "$( echo "ansible $opts_adhoc $@" | sed 's/,/_/g' ),$out,$rc,$start,$end" >>$logs/measurement.log
    return $rc
}
function ap() {
    local out=$1; shift
    local start=$( date +%s )
    log "Start 'ansible-playbook $opts $*' with log in $out"
    ansible-playbook $opts "$@" &>$out
    rc=$?
    local end=$( date +%s )
    log "Finish after $( expr $end - $start ) seconds with exit code $rc"
    echo "$( echo "ansible-playbook $opts_adhoc $@" | sed 's/,/_/g' ),$out,$rc,$start,$end" >>$logs/measurement.log
    return $rc
}
function s() {
    log "Sleep for $1 seconds"
    sleep $1
}


###a $logs/00-manifest-deploy.log -m copy -a "src=$manifest dest=/root/manifest-auto.zip force=yes" satellite6
###for i in 1 2 3; do
###    a $logs/01-manifest-upload-$i.log -m "shell" -a "hammer --username admin --password changeme subscription upload --file '/root/manifest-auto.zip' --organization '$do'" satellite6
###    s 10
###    if [ $i -lt 3 ]; then
###        a $logs/02-manifest-delete-$i.log -m "shell" -a "hammer --username admin --password changeme subscription delete-manifest --organization '$do'" satellite6
###        s 10
###    fi
###done
###a $logs/03-manifest-refresh.log -m "shell" -a "hammer --username admin --password changeme subscription refresh-manifest --organization '$do'" satellite6
###s 100


###a $logs/10-reposet-enable-rhel7.log -m "shell" -a "hammer --username admin --password changeme repository-set enable --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server (RPMs)' --releasever '7Server' --basearch 'x86_64'" satellite6
###a $logs/10-reposet-enable-rhel6.log -m "shell" -a "hammer --username admin --password changeme repository-set enable --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 6 Server (RPMs)' --releasever '6Server' --basearch 'x86_64'" satellite6
###a $logs/10-reposet-enable-rhel7optional.log -m "shell" -a "hammer --username admin --password changeme repository-set enable --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server - Optional (RPMs)' --releasever '7Server' --basearch 'x86_64'" satellite6
###a $logs/11-repo-immediate-rhel7.log -m "shell" -a "hammer --username admin --password changeme repository update --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server' --download-policy 'immediate'" satellite6
a $logs/10-repo-sync-rhel7.log -m "shell" -a "hammer --username admin --password changeme repository synchronize --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server (RPMs)'" satellite6
s 100
a $logs/10-repo-sync-rhel6.log -m "shell" -a "hammer --username admin --password changeme repository synchronize --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 6 Server (RPMs)'" satellite6
s 100
a $logs/10-repo-sync-rhel7optional.log -m "shell" -a "hammer --username admin --password changeme repository synchronize --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server - Optional (RPMs)'" satellite6
s 100
