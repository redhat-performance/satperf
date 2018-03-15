#!/bin/bash

source run-library.sh

manifest="conf/2018-03-13-retpoline-on-vm/manifest.zip"
do="Default Organization"
registrations_per_docker_hosts=10
registrations_iterations=40

opts="--forks 100 -i conf/2018-03-13-retpoline-on-vm/inventory.ini --private-key conf/2018-03-13-retpoline-on-vm/id_rsa_perf"
opts_adhoc="$opts --user root"


###yes | satellite-installer --scenario satellite --reset

a 00-satellite-drop-caches.log -m shell -a "katello-service stop; sync; echo 3 > /proc/sys/vm/drop_caches; katello-service start" satellite6
s 300
a 00-manifest-deploy.log -m copy -a "src=$manifest dest=/root/manifest-auto.zip force=yes" satellite6
for i in 1 2 3; do
    a 01-manifest-upload-$i.log -m "shell" -a "hammer --username admin --password changeme subscription upload --file '/root/manifest-auto.zip' --organization '$do'" satellite6
    s 10
    if [ $i -lt 3 ]; then
        a 02-manifest-delete-$i.log -m "shell" -a "hammer --username admin --password changeme subscription delete-manifest --organization '$do'" satellite6
        s 10
    fi
done
a 03-manifest-refresh.log -m "shell" -a "hammer --username admin --password changeme subscription refresh-manifest --organization '$do'" satellite6
s 100


a 10-reposet-enable-rhel7.log -m "shell" -a "hammer --username admin --password changeme repository-set enable --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server (RPMs)' --releasever '7Server' --basearch 'x86_64'" satellite6
a 10-reposet-enable-rhel6.log -m "shell" -a "hammer --username admin --password changeme repository-set enable --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 6 Server (RPMs)' --releasever '6Server' --basearch 'x86_64'" satellite6
a 10-reposet-enable-rhel7optional.log -m "shell" -a "hammer --username admin --password changeme repository-set enable --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server - Optional (RPMs)' --releasever '7Server' --basearch 'x86_64'" satellite6
a 11-repo-immediate-rhel7.log -m "shell" -a "hammer --username admin --password changeme repository update --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server' --download-policy 'immediate'" satellite6
a 12-repo-sync-rhel7.log -m "shell" -a "hammer --username admin --password changeme repository synchronize --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server'" satellite6
s 100
a 12-repo-sync-rhel6.log -m "shell" -a "hammer --username admin --password changeme repository synchronize --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 6 Server RPMs x86_64 6Server'" satellite6
s 100
a 12-repo-sync-rhel7optional.log -m "shell" -a "hammer --username admin --password changeme repository synchronize --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server - Optional RPMs x86_64 7Server'" satellite6
s 100


a 20-cv-create-all.log satellite6 -m "shell" -a "hammer --username admin --password changeme content-view create --organization '$do' --product 'Red Hat Enterprise Linux Server' --repositories 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server','Red Hat Enterprise Linux 6 Server RPMs x86_64 6Server','Red Hat Enterprise Linux 7 Server - Optional RPMs x86_64 7Server' --name 'BenchContentView'"
a 21-cv-all-publish.log satellite6 -m "shell" -a "hammer --username admin --password changeme content-view publish --organization '$do' --name 'BenchContentView'"
s 100
a 22-le-create-1.log satellite6 -m "shell" -a "hammer --username admin --password changeme lifecycle-environment create --organization '$do' --prior 'Library' --name 'BenchLifeEnvAAA'"
a 22-le-create-2.log satellite6 -m "shell" -a "hammer --username admin --password changeme lifecycle-environment create --organization '$do' --prior 'BenchLifeEnvAAA' --name 'BenchLifeEnvBBB'"
a 22-le-create-3.log satellite6 -m "shell" -a "hammer --username admin --password changeme lifecycle-environment create --organization '$do' --prior 'BenchLifeEnvBBB' --name 'BenchLifeEnvCCC'"
a 23-cv-all-promote-1.log satellite6 -m "shell" -a "hammer --username admin --password changeme content-view version promote --organization 'Default Organization' --content-view 'BenchContentView' --to-lifecycle-environment 'Library' --to-lifecycle-environment 'BenchLifeEnvAAA'"
s 100
a 23-cv-all-promote-2.log satellite6 -m "shell" -a "hammer --username admin --password changeme content-view version promote --organization 'Default Organization' --content-view 'BenchContentView' --to-lifecycle-environment 'BenchLifeEnvAAA' --to-lifecycle-environment 'BenchLifeEnvBBB'"
s 100
a 23-cv-all-promote-3.log satellite6 -m "shell" -a "hammer --username admin --password changeme content-view version promote --organization 'Default Organization' --content-view 'BenchContentView' --to-lifecycle-environment 'BenchLifeEnvBBB' --to-lifecycle-environment 'BenchLifeEnvCCC'"
s 100


a 30-cv-create-filtered.log satellite6 -m "shell" -a "hammer --username admin --password changeme content-view create --organization '$do' --product 'Red Hat Enterprise Linux Server' --repositories 'Red Hat Enterprise Linux 6 Server RPMs x86_64 6Server' --name 'BenchFilteredContentView'"
a 31-filter-create-1.log satellite6 -m "shell" -a "hammer --username admin --password changeme content-view filter create --organization '$do' --type erratum --inclusion true --content-view BenchFilteredContentView --name BenchFilterAAA"
a 31-filter-create-2.log satellite6 -m "shell" -a "hammer --username admin --password changeme content-view filter create --organization '$do' --type erratum --inclusion true --content-view BenchFilteredContentView --name BenchFilterBBB"
a 32-rule-create-1.log satellite6 -m "shell" -a "hammer --username admin --password changeme content-view filter rule create --content-view BenchFilteredContentView --content-view-filter BenchFilterAAA --date-type 'issued' --start-date 2016-01-01 --end-date 2017-10-01 --organization '$do' --types enhancement,bugfix,security"
a 32-rule-create-2.log satellite6 -m "shell" -a "hammer --username admin --password changeme content-view filter rule create --content-view BenchFilteredContentView --content-view-filter BenchFilterBBB --date-type 'updated' --start-date 2016-01-01 --end-date 2018-01-01 --organization '$do' --types security"
a 33-cv-filtered-publish.log satellite6 -m "shell" -a "hammer --username admin --password changeme content-view publish --organization '$do' --name 'BenchFilteredContentView'"
s 100


ap 40-recreate-containers.log playbooks/docker/docker-tierdown.yaml playbooks/docker/docker-tierup.yaml
ap 40-recreate-client-scripts.log playbooks/satellite/client-scripts.yaml
a 41-hostgroup-create.log satellite6 -m "shell" -a "hammer --username admin --password changeme hostgroup create --content-view 'Default Organization View' --lifecycle-environment Library --name HostGroup --query-organization '$do'"
a 42-domain-create.log satellite6 -m "shell" -a "hammer --username admin --password changeme domain create --name example.com --organizations '$do'"
a 43-ak-create.log satellite6 -m "shell" -a "hammer --username admin --password changeme activation-key create --content-view 'Default Organization View' --lifecycle-environment Library --name ActivationKey --organization '$do'"
for i in $( seq $registrations_iterations ); do
    ap 44-register-$i.log playbooks/tests/registrations.yaml -e "size=$registrations_per_docker_hosts tags=untagged,REG,REM bootstrap_operatingsystem='RedHat 7.4' bootstrap_activationkey='ActivationKey' bootstrap_hostgroup='HostGroup' grepper='Register'"
    s 120
done


a 50-rex-set-via-ip.log satellite6 -m "shell" -a "hammer --username admin --password changeme settings set --name remote_execution_connect_by_ip --value true"
a 51-rex-cleanup-know_hosts.log satellite6 -m "shell" -a "rm -rf /usr/share/foreman-proxy/.ssh/known_hosts*"
a 52-rex-date.log satellite6 -m "shell" -a "hammer --username admin --password changeme job-invocation create --inputs \"command='date'\" --job-template 'Run Command - SSH Default' --search-query 'name ~ container'"
s 120
a 53-rex-sm-facts-update.log satellite6 -m "shell" -a "hammer --username admin --password changeme job-invocation create --inputs \"command='subscription-manager facts --update'\" --job-template 'Run Command - SSH Default' --search-query 'name ~ container'"


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
