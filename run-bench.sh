#!/bin/sh

manifest="/home/pok/DownloadsWork/manifest_ed59abc3-32d7-45fe-bcaf-0160e588a0a6.zip"
do="Default Organization"
logs="logs-$( date --iso-8601=seconds )"
mkdir "$logs/"
registrations_per_docker_hosts=13

opts="--forks 100 -i conf/20180112-scale-meltdown-spectre.ini --private-key conf/id_rsa_perf"
opts_adhoc="$opts --user root"

if ! type bc >/dev/null; then
    echo "ERROR: bc not installed" >&2
    exit 1
fi
if ! type ansible >/dev/null; then
    echo "ERROR: ansible not installed" >&2
    exit 1
fi

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


log "Logging into '$logs/' directory"


a $logs/00-manifest-deploy.log -m copy -a "src=$manifest dest=/root/manifest-auto.zip force=yes" satellite6
for i in 1 2 3; do
    a $logs/01-manifest-upload-$i.log -m "shell" -a "hammer --username admin --password changeme subscription upload --file '/root/manifest-auto.zip' --organization '$do'" satellite6
    s 10
    if [ $i -lt 3 ]; then
        a $logs/02-manifest-delete-$i.log -m "shell" -a "hammer --username admin --password changeme subscription delete-manifest --organization '$do'" satellite6
        s 10
    fi
done
a $logs/03-manifest-refresh.log -m "shell" -a "hammer --username admin --password changeme subscription refresh-manifest --organization '$do'" satellite6
s 100


a $logs/10-reposet-enable-rhel7.log -m "shell" -a "hammer --username admin --password changeme repository-set enable --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server (RPMs)' --releasever '7Server' --basearch 'x86_64'" satellite6
a $logs/10-reposet-enable-rhel6.log -m "shell" -a "hammer --username admin --password changeme repository-set enable --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 6 Server (RPMs)' --releasever '6Server' --basearch 'x86_64'" satellite6
a $logs/10-reposet-enable-rhel7optional.log -m "shell" -a "hammer --username admin --password changeme repository-set enable --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server - Optional (RPMs)' --releasever '7Server' --basearch 'x86_64'" satellite6
a $logs/11-repo-immediate-rhel7.log -m "shell" -a "hammer --username admin --password changeme repository update --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server' --download-policy 'immediate'" satellite6
a $logs/12-repo-sync-rhel7.log -m "shell" -a "hammer --username admin --password changeme repository synchronize --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server'" satellite6
s 100
a $logs/12-repo-sync-rhel6.log -m "shell" -a "hammer --username admin --password changeme repository synchronize --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 6 Server RPMs x86_64 6Server'" satellite6
s 100
a $logs/12-repo-sync-rhel7optional.log -m "shell" -a "hammer --username admin --password changeme repository synchronize --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server - Optional RPMs x86_64 7Server'" satellite6
s 100


a $logs/20-cv-create-all.log satellite6 -m "shell" -a "hammer --username admin --password changeme content-view create --organization '$do' --product 'Red Hat Enterprise Linux Server' --repositories 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server','Red Hat Enterprise Linux 6 Server RPMs x86_64 6Server','Red Hat Enterprise Linux 7 Server - Optional RPMs x86_64 7Server' --name 'BenchContentView'"
a $logs/21-cv-all-publish.log satellite6 -m "shell" -a "hammer --username admin --password changeme content-view publish --organization '$do' --name 'BenchContentView'"
s 100
a $logs/22-le-create-1.log satellite6 -m "shell" -a "hammer --username admin --password changeme lifecycle-environment create --organization '$do' --prior 'Library' --name 'BenchLifeEnvAAA'"
a $logs/22-le-create-2.log satellite6 -m "shell" -a "hammer --username admin --password changeme lifecycle-environment create --organization '$do' --prior 'BenchLifeEnvAAA' --name 'BenchLifeEnvBBB'"
a $logs/22-le-create-3.log satellite6 -m "shell" -a "hammer --username admin --password changeme lifecycle-environment create --organization '$do' --prior 'BenchLifeEnvBBB' --name 'BenchLifeEnvCCC'"
a $logs/23-cv-all-promote-1.log satellite6 -m "shell" -a "hammer --username admin --password changeme content-view version promote --organization 'Default Organization' --content-view 'BenchContentView' --to-lifecycle-environment 'Library' --to-lifecycle-environment 'BenchLifeEnvAAA'"
s 100
a $logs/23-cv-all-promote-2.log satellite6 -m "shell" -a "hammer --username admin --password changeme content-view version promote --organization 'Default Organization' --content-view 'BenchContentView' --to-lifecycle-environment 'BenchLifeEnvAAA' --to-lifecycle-environment 'BenchLifeEnvBBB'"
s 100
a $logs/23-cv-all-promote-3.log satellite6 -m "shell" -a "hammer --username admin --password changeme content-view version promote --organization 'Default Organization' --content-view 'BenchContentView' --to-lifecycle-environment 'BenchLifeEnvBBB' --to-lifecycle-environment 'BenchLifeEnvCCC'"
s 100


a $logs/30-cv-create-filtered.log satellite6 -m "shell" -a "hammer --username admin --password changeme content-view create --organization '$do' --product 'Red Hat Enterprise Linux Server' --repositories 'Red Hat Enterprise Linux 6 Server RPMs x86_64 6Server' --name 'BenchFilteredContentView'"
a $logs/31-filter-create-1.log satellite6 -m "shell" -a "hammer --username admin --password changeme content-view filter create --organization '$do' --type erratum --inclusion true --content-view BenchFilteredContentView --name BenchFilterAAA"
a $logs/31-filter-create-2.log satellite6 -m "shell" -a "hammer --username admin --password changeme content-view filter create --organization '$do' --type erratum --inclusion true --content-view BenchFilteredContentView --name BenchFilterBBB"
a $logs/32-rule-create-1.log satellite6 -m "shell" -a "hammer --username admin --password changeme content-view filter rule create --content-view BenchFilteredContentView --content-view-filter BenchFilterAAA --date-type 'issued' --start-date 2016-01-01 --end-date 2017-10-01 --organization '$do' --types enhancement,bugfix,security"
a $logs/32-rule-create-2.log satellite6 -m "shell" -a "hammer --username admin --password changeme content-view filter rule create --content-view BenchFilteredContentView --content-view-filter BenchFilterBBB --date-type 'updated' --start-date 2016-01-01 --end-date 2018-01-01 --organization '$do' --types security"
a $logs/33-cv-filtered-publish.log satellite6 -m "shell" -a "hammer --username admin --password changeme content-view publish --organization '$do' --name 'BenchFilteredContentView'"
s 100


ap $logs/40-recreate-containers.log playbooks/docker/docker-tierdown.yaml playbooks/docker/docker-tierup.yaml
ap $logs/40-recreate-client-scripts.log playbooks/satellite/client-scripts.yaml
a $logs/41-hostgroup-create.log satellite6 -m "shell" -a "hammer --username admin --password changeme hostgroup create --content-view 'Default Organization View' --lifecycle-environment Library --name HostGroup --query-organization '$do'"
a $logs/42-domain-create.log satellite6 -m "shell" -a "hammer --username admin --password changeme domain create --name example.com --organizations '$do'"
a $logs/43-ak-create.log satellite6 -m "shell" -a "hammer --username admin --password changeme activation-key create --content-view 'Default Organization View' --lifecycle-environment Library --name ActivationKey --organization '$do'"
for i in $( seq 19 ); do
    ap $logs/44-register-$i.log playbooks/tests/registrations.yaml -e "size=$registrations_per_docker_hosts tags=untagged,REG,REM bootstrap_operatingsystem='RHEL Server 7.4'"
    s 120
done


a $logs/50-rex-set-via-ip.log satellite6 -m "shell" -a "hammer --username admin --password changeme settings set --name remote_execution_connect_by_ip --value true"
a $logs/51-rex-cleanup-know_hosts.log satellite6 -m "shell" -a "true > /usr/share/foreman-proxy/.ssh/known_hosts"
a $logs/52-rex-date.log satellite6 -m "shell" -a "hammer --username admin --password changeme job-invocation create --inputs \"command='date'\" --job-template 'Run Command - SSH Default' --search-query 'name ~ container'"
s 120
a $logs/53-rex-sm-facts-update.log satellite6 -m "shell" -a "hammer --username admin --password changeme job-invocation create --inputs \"command='subscription-manager facts --update'\" --job-template 'Run Command - SSH Default' --search-query 'name ~ container'"


function table_row() {
    local identifier="/$( echo "$1" | sed 's/\./\./g' ),"
    local description="$2"
    export IFS=$'\n'
    local count=0
    local sum=0
    local note=""
    for row in $( grep "$identifier" $logs/measurement.log ); do
        local rc="$( echo "$row" | cut -d ',' -f 3 )"
        if [ "$rc" -ne 0 ]; then
            echo "ERROR: Row '$row' have non-zero return code. Not considering it when counting duration :-(" >&2
            continue
        fi
        if echo "$identifier" | grep --quiet -- "-register-"; then
            local log="$( echo "$row" | cut -d ',' -f 2 )"
            local out=$( ./reg-average.sh "Register" "$log" | tail -n 1 )
            local passed=$( echo "$out" | cut -d ' ' -f 4 )
            [ -z "$note" ] && note="Number of passed regs:"
            local note="$note $passed"
            local diff=$( echo "$out" | cut -d ' ' -f 6 )
            let sum+=$diff
            let count+=1
        else
            local start="$( echo "$row" | cut -d ',' -f 4 )"
            local end="$( echo "$row" | cut -d ',' -f 5 )"
            let sum+=$( expr "$end" - "$start" )
            let count+=1
        fi
    done
    if [ "$count" -eq 0 ]; then
        local avg="N/A"
    else
        local avg=$( echo "scale=2; $sum / $count" | bc )
    fi
    echo -e "$description\t$avg\t$note"
}

log "Formatting results:"
table_row "01-manifest-upload-[0-9]\+.log" "Manifest upload"
table_row "12-repo-sync-rhel7.log" "Sync RHEL7 (immediate)"
table_row "12-repo-sync-rhel6.log" "Sync RHEL6 (on-demand)"
table_row "12-repo-sync-rhel7optional.log" "Sync RHEL7 Optional (on-demand)"
table_row "21-cv-all-publish.log" "Publish big CV"
table_row "23-cv-all-promote-[0-9]\+.log" "Promote big CV"
table_row "33-cv-filtered-publish.log" "Publish smaller filtered CV"
table_row "44-register-[0-9]\+.log" "Register bunch of containers"
table_row "52-rex-date.log" "ReX 'date' on all containers"
table_row "53-rex-sm-facts-update.log" "ReX 'subscription-manager facts --update' on all containers"
