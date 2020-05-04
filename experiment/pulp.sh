#!/bin/sh

source experiment/run-library.sh

manifest="${PARAM_manifest:-conf/contperf/manifest.zip}"
inventory="${PARAM_inventory:-conf/contperf/inventory.ini}"
private_key="${PARAM_private_key:-conf/contperf/id_rsa_perf}"

wait_interval=${PARAM_wait_interval:-50}

cdn_url_mirror="${PARAM_cdn_url_mirror:-https://cdn.redhat.com/}"
cdn_url_full="${PARAM_cdn_url_full:-https://cdn.redhat.com/}"

do="Default Organization"
dl="Default Location"

opts="--forks 100 -i $inventory --private-key $private_key"
opts_adhoc="$opts --user root -e @conf/satperf.yaml -e @conf/satperf.local.yaml"


section "Checking environment"
generic_environment_check


section "Prepare for Red Hat content"
h 00-ensure-loc-in-org.log "organization add-location --name 'Default Organization' --location 'Default Location'"
a 00-manifest-deploy.log -m copy -a "src=$manifest dest=/root/manifest-auto.zip force=yes" satellite6
count=5
for i in $( seq $count ); do
    h 01-manifest-upload-$i.log "subscription upload --file '/root/manifest-auto.zip' --organization '$do'"
    s $wait_interval
    if [ $i -lt $count ]; then
        h 02-manifest-delete-$i.log "subscription delete-manifest --organization '$do'"
        s $wait_interval
    fi
done
h 03-manifest-refresh.log "subscription refresh-manifest --organization '$do'"
s $wait_interval


section "Sync from mirror"
h 00-set-local-cdn-mirror.log "organization update --name 'Default Organization' --redhat-repository-url '$cdn_url_mirror'"
h 10-reposet-enable-rhel7.log  "repository-set enable --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server (RPMs)' --releasever '7Server' --basearch 'x86_64'"
h 10-reposet-enable-rhel6.log  "repository-set enable --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 6 Server (RPMs)' --releasever '6Server' --basearch 'x86_64'"
h 12-repo-sync-rhel7.log "repository synchronize --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server'"
s $wait_interval
h 12-repo-sync-rhel6.log "repository synchronize --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 6 Server RPMs x86_64 6Server'"
s $wait_interval


section "Publish and promote big CV"
rids=""
for r in 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server' 'Red Hat Enterprise Linux 6 Server RPMs x86_64 6Server'; do
    tmp=$( mktemp )
    h_out "--output yaml repository info --organization '$do' --product 'Red Hat Enterprise Linux Server' --name '$r'" >$tmp
    rid=$( grep '^ID:' $tmp | cut -d ' ' -f 2 )
    [ ${#rids} -eq 0 ] && rids="$rid" || rids="$rids,$rid"
done
h 20-cv-create-all.log "content-view create --organization '$do' --repository-ids '$rids' --name 'BenchContentView'"
h 21-cv-all-publish.log "content-view publish --organization '$do' --name 'BenchContentView'"
s $wait_interval
h 22-le-create-1.log "lifecycle-environment create --organization '$do' --prior 'Library' --name 'BenchLifeEnvAAA'"
h 22-le-create-2.log "lifecycle-environment create --organization '$do' --prior 'BenchLifeEnvAAA' --name 'BenchLifeEnvBBB'"
h 22-le-create-3.log "lifecycle-environment create --organization '$do' --prior 'BenchLifeEnvBBB' --name 'BenchLifeEnvCCC'"
h 23-cv-all-promote-1.log "content-view version promote --organization 'Default Organization' --content-view 'BenchContentView' --to-lifecycle-environment 'Library' --to-lifecycle-environment 'BenchLifeEnvAAA'"
s $wait_interval
h 23-cv-all-promote-2.log "content-view version promote --organization 'Default Organization' --content-view 'BenchContentView' --to-lifecycle-environment 'BenchLifeEnvAAA' --to-lifecycle-environment 'BenchLifeEnvBBB'"
s $wait_interval
h 23-cv-all-promote-3.log "content-view version promote --organization 'Default Organization' --content-view 'BenchContentView' --to-lifecycle-environment 'BenchLifeEnvBBB' --to-lifecycle-environment 'BenchLifeEnvCCC'"
s $wait_interval


section "Publish and promote filtered CV"
rids=""
for r in 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server' 'Red Hat Enterprise Linux 6 Server RPMs x86_64 6Server'; do
    tmp=$( mktemp )
    h_out "--output yaml repository info --organization '$do' --product 'Red Hat Enterprise Linux Server' --name '$r'" >$tmp
    rid=$( grep '^ID:' $tmp | cut -d ' ' -f 2 )
    [ ${#rids} -eq 0 ] && rids="$rid" || rids="$rids,$rid"
done
h 30-cv-create-filtered.log "content-view create --organization '$do' --repository-ids '$rids' --name 'BenchFilteredContentView'"
h 31-filter-create-1.log "content-view filter create --organization '$do' --type erratum --inclusion true --content-view BenchFilteredContentView --name BenchFilterAAA"
h 31-filter-create-2.log "content-view filter create --organization '$do' --type erratum --inclusion true --content-view BenchFilteredContentView --name BenchFilterBBB"
h 32-rule-create-1.log "content-view filter rule create --content-view BenchFilteredContentView --content-view-filter BenchFilterAAA --date-type 'issued' --start-date 2016-01-01 --end-date 2017-10-01 --organization '$do' --types enhancement,bugfix,security"
h 32-rule-create-2.log "content-view filter rule create --content-view BenchFilteredContentView --content-view-filter BenchFilterBBB --date-type 'updated' --start-date 2016-01-01 --end-date 2018-01-01 --organization '$do' --types security"
h 33-cv-filtered-publish.log "content-view publish --organization '$do' --name 'BenchFilteredContentView'"
s $wait_interval
