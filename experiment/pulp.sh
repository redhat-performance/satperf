#!/bin/sh

source experiment/run-library.sh

organization="${PARAM_organization:-Default Organization}"
manifest="${PARAM_manifest:-conf/contperf/manifest.zip}"
inventory="${PARAM_inventory:-conf/contperf/inventory.ini}"
private_key="${PARAM_private_key:-conf/contperf/id_rsa_perf}"
local_conf="${PARAM_local_conf:-conf/satperf.local.yaml}"

wait_interval=${PARAM_wait_interval:-50}

cdn_url_mirror="${PARAM_cdn_url_mirror:-https://cdn.redhat.com/}"
cdn_url_full="${PARAM_cdn_url_full:-https://cdn.redhat.com/}"

PARAM_docker_registry=${PARAM_docker_registry:-https://registry-1.docker.io/}

PARAM_iso_repos=${PARAM_iso_repos:-http://storage.example.com/iso-repos/}

dl="Default Location"

opts="--forks 100 -i $inventory --private-key $private_key"
opts_adhoc="$opts -e @conf/satperf.yaml -e @$local_conf"


section "Checking environment"
generic_environment_check


section "Prepare for Red Hat content"
h_out "--no-headers --csv organization list --fields name" | grep --quiet "^$organization$" \
    || h 00-ensure-org.log "organization create --name '$organization'"
h 00-ensure-loc-in-org.log "organization add-location --name '$organization' --location 'Default Location'"
a 00-manifest-deploy.log -m copy -a "src=$manifest dest=/root/manifest-auto.zip force=yes" satellite6
count=5
for i in $( seq $count ); do
    h 01-manifest-upload-$i.log "subscription upload --file '/root/manifest-auto.zip' --organization '$organization'"
    s $wait_interval
    if [ $i -lt $count ]; then
        h 02-manifest-delete-$i.log "subscription delete-manifest --organization '$organization'"
        s $wait_interval
    fi
done
h 03-manifest-refresh.log "subscription refresh-manifest --organization '$organization'"
s $wait_interval


section "Sync from mirror"
h 00-set-local-cdn-mirror.log "organization update --name '$organization' --redhat-repository-url '$cdn_url_mirror'"
h 10-reposet-enable-rhel7.log  "repository-set enable --organization '$organization' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server (RPMs)' --releasever '7Server' --basearch 'x86_64'"
h 10-reposet-enable-rhel6.log  "repository-set enable --organization '$organization' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 6 Server (RPMs)' --releasever '6Server' --basearch 'x86_64'"
h 12-repo-sync-rhel7.log "repository synchronize --organization '$organization' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server'"
s $wait_interval
h 12-repo-sync-rhel6.log "repository synchronize --organization '$organization' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 6 Server RPMs x86_64 6Server'"
s $wait_interval


section "Sync from Docker hub"
h 20-create-docker-product.log "product create --organization '$organization' --name 'BenchDockerHubProduct'"
# TODO: Add more repos?
# TODO: Sync from local mirror
h 21-create-docker-repo.log "repository create --organization '$organization' --product 'BenchDockerHubProduct' --content-type 'docker' --url '$PARAM_docker_registry' --docker-upstream-name 'busybox' --name 'RepoBusyboxAll'"
h 22-repo-sync-docker.log "repository synchronize --organization '$organization' --product 'BenchDockerHubProduct' --name 'RepoBusyboxAll'"


section "Sync file repo"
h 30-create-file-product.log "product create --organization '$organization' --name 'BenchIsoProduct'"
for r in 'file-100k-100kB-A'; do   # TODO: Add more?
    h 31-create-file-repo-$r.log "repository create --organization '$organization' --product 'BenchIsoProduct' --content-type 'file' --url '$PARAM_iso_repos/$r/' --name 'Repo$r'"
    h 32-repo-sync-file-$r.log "repository synchronize --organization '$organization' --product 'BenchIsoProduct' --name 'Repo$r'"
done


section "Prepare for publish and promote"
h 22-le-create-1.log "lifecycle-environment create --organization '$organization' --prior 'Library' --name 'BenchLifeEnvAAA'"
h 22-le-create-2.log "lifecycle-environment create --organization '$organization' --prior 'BenchLifeEnvAAA' --name 'BenchLifeEnvBBB'"
h 22-le-create-3.log "lifecycle-environment create --organization '$organization' --prior 'BenchLifeEnvBBB' --name 'BenchLifeEnvCCC'"


section "Publish and promote big CV"
rids="$( get_repo_id 'Red Hat Enterprise Linux Server' 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server' )"
rids="$rids,$( get_repo_id 'Red Hat Enterprise Linux Server' 'Red Hat Enterprise Linux 6 Server RPMs x86_64 6Server' )"
h 20-cv-create-all.log "content-view create --organization '$organization' --repository-ids '$rids' --name 'BenchContentView'"
h 21-cv-all-publish.log "content-view publish --organization '$organization' --name 'BenchContentView'"
s $wait_interval
h 22-cv-all-promote-1.log "content-view version promote --organization '$organization' --content-view 'BenchContentView' --to-lifecycle-environment 'Library' --to-lifecycle-environment 'BenchLifeEnvAAA'"
s $wait_interval
h 22-cv-all-promote-2.log "content-view version promote --organization '$organization' --content-view 'BenchContentView' --to-lifecycle-environment 'BenchLifeEnvAAA' --to-lifecycle-environment 'BenchLifeEnvBBB'"
s $wait_interval
h 22-cv-all-promote-3.log "content-view version promote --organization '$organization' --content-view 'BenchContentView' --to-lifecycle-environment 'BenchLifeEnvBBB' --to-lifecycle-environment 'BenchLifeEnvCCC'"
s $wait_interval


section "Publish and promote filtered CV"
rids="$( get_repo_id 'Red Hat Enterprise Linux Server' 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server' )"
rids="$rids,$( get_repo_id 'Red Hat Enterprise Linux Server' 'Red Hat Enterprise Linux 6 Server RPMs x86_64 6Server' )"
h 30-cv-create-filtered.log "content-view create --organization '$organization' --repository-ids '$rids' --name 'BenchFilteredContentView'"
h 31-filter-create-1.log "content-view filter create --organization '$organization' --type erratum --inclusion true --content-view BenchFilteredContentView --name BenchFilterAAA"
h 31-filter-create-2.log "content-view filter create --organization '$organization' --type erratum --inclusion true --content-view BenchFilteredContentView --name BenchFilterBBB"
h 32-rule-create-1.log "content-view filter rule create --content-view BenchFilteredContentView --content-view-filter BenchFilterAAA --date-type 'issued' --start-date 2016-01-01 --end-date 2017-10-01 --organization '$organization' --types enhancement,bugfix,security"
h 32-rule-create-2.log "content-view filter rule create --content-view BenchFilteredContentView --content-view-filter BenchFilterBBB --date-type 'updated' --start-date 2016-01-01 --end-date 2018-01-01 --organization '$organization' --types security"
h 33-cv-filtered-publish.log "content-view publish --organization '$organization' --name 'BenchFilteredContentView'"
s $wait_interval
h 34-cv-filtered-promote-1.log "content-view version promote --organization '$organization' --content-view 'BenchFilteredContentView' --to-lifecycle-environment 'Library' --to-lifecycle-environment 'BenchLifeEnvAAA'"
s $wait_interval
h 34-cv-filtered-promote-2.log "content-view version promote --organization '$organization' --content-view 'BenchFilteredContentView' --to-lifecycle-environment 'BenchLifeEnvAAA' --to-lifecycle-environment 'BenchLifeEnvBBB'"
s $wait_interval
h 34-cv-filtered-promote-3.log "content-view version promote --organization '$organization' --content-view 'BenchFilteredContentView' --to-lifecycle-environment 'BenchLifeEnvBBB' --to-lifecycle-environment 'BenchLifeEnvCCC'"
s $wait_interval


section "Publish and promote mixed content CV"
rids="$( get_repo_id 'Red Hat Enterprise Linux Server' 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server' )"
rids="$rids,$( get_repo_id 'Red Hat Enterprise Linux Server' 'Red Hat Enterprise Linux 6 Server RPMs x86_64 6Server' )"
rids="$rids,$( get_repo_id 'BenchDockerHubProduct' 'RepoBusyboxAll' )"
rids="$rids,$( get_repo_id 'BenchIsoProduct' 'Repofile-100k-100kB-A' )"
h 60-cv-create-mixed.log "content-view create --organization '$organization' --repository-ids '$rids' --name 'BenchMixedContentContentView'"
h 61-cv-mixed-publish.log "content-view publish --organization '$organization' --name 'BenchMixedContentContentView'"
s $wait_interval
h 62-cv-mixed-promote-1.log "content-view version promote --organization '$organization' --content-view 'BenchMixedContentContentView' --to-lifecycle-environment 'Library' --to-lifecycle-environment 'BenchLifeEnvAAA'"
s $wait_interval
h 62-cv-mixed-promote-2.log "content-view version promote --organization '$organization' --content-view 'BenchMixedContentContentView' --to-lifecycle-environment 'BenchLifeEnvAAA' --to-lifecycle-environment 'BenchLifeEnvBBB'"
s $wait_interval
h 62-cv-mixed-promote-3.log "content-view version promote --organization '$organization' --content-view 'BenchMixedContentContentView' --to-lifecycle-environment 'BenchLifeEnvBBB' --to-lifecycle-environment 'BenchLifeEnvCCC'"
s $wait_interval
