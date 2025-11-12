#!/bin/sh

source experiment/run-library.sh

cdn_url_mirror="${PARAM_cdn_url_mirror:-https://cdn.redhat.com/}"
cdn_url_full="${PARAM_cdn_url_full:-https://cdn.redhat.com/}"

PARAM_docker_registry=${PARAM_docker_registry:-https://registry-1.docker.io/}

PARAM_iso_repos=${PARAM_iso_repos:-http://storage.example.com/iso-repos/}


section 'Checking environment'
generic_environment_check
# unset skip_measurement
# set +e


section 'Prepare for Red Hat content'
test=09f-manifest-download
skip_measurement=true apj $test \
  playbooks/tests/FAM/manifest_download.yaml

test=09f-manifest-import
skip_measurement=true apj $test \
  playbooks/tests/FAM/manifest_import.yaml


section "Sync from mirror"
h 00-set-local-cdn-mirror.log "organization update --name '{{ sat_org }}' --redhat-repository-url '$cdn_url_mirror'"
h 10-reposet-enable-rhel7.log  "repository-set enable --organization '{{ sat_org }}' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server (RPMs)' --releasever '7Server' --basearch 'x86_64'"
h 10-reposet-enable-rhel6.log  "repository-set enable --organization '{{ sat_org }}' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 6 Server (RPMs)' --releasever '6Server' --basearch 'x86_64'"
h 12-repo-sync-rhel7.log "repository synchronize --organization '{{ sat_org }}' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server'"
h 12-repo-sync-rhel6.log "repository synchronize --organization '{{ sat_org }}' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 6 Server RPMs x86_64 6Server'"


section "Sync from Docker hub"
h 20-create-docker-product.log "product create --organization '{{ sat_org }}' --name 'BenchDockerHubProduct'"
# TODO: Add more repos?
# TODO: Sync from local mirror
h 21-create-docker-repo.log "repository create --organization '{{ sat_org }}' --product 'BenchDockerHubProduct' --content-type 'docker' --url '$PARAM_docker_registry' --docker-upstream-name 'busybox' --name 'RepoBusyboxAll'"
h 22-repo-sync-docker.log "repository synchronize --organization '{{ sat_org }}' --product 'BenchDockerHubProduct' --name 'RepoBusyboxAll'"


section "Sync file repo"
h 30-create-file-product.log "product create --organization '{{ sat_org }}' --name 'BenchIsoProduct'"
for r in 'file-100k-100kB-A'; do   # TODO: Add more?
    h 31-create-file-repo-$r.log "repository create --organization '{{ sat_org }}' --product 'BenchIsoProduct' --content-type 'file' --url '$PARAM_iso_repos/$r/' --name 'Repo$r'"
    h 32-repo-sync-file-$r.log "repository synchronize --organization '{{ sat_org }}' --product 'BenchIsoProduct' --name 'Repo$r'"
done


section "Prepare for publish and promote"
h 22-le-create-1.log "lifecycle-environment create --organization '{{ sat_org }}' --prior 'Library' --name 'BenchLifeEnvAAA'"
h 22-le-create-2.log "lifecycle-environment create --organization '{{ sat_org }}' --prior 'BenchLifeEnvAAA' --name 'BenchLifeEnvBBB'"
h 22-le-create-3.log "lifecycle-environment create --organization '{{ sat_org }}' --prior 'BenchLifeEnvBBB' --name 'BenchLifeEnvCCC'"


section "Publish and promote big CV"
rids="$( get_repo_id '{{ sat_org }}' 'Red Hat Enterprise Linux Server' 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server' )"
rids="$rids,$( get_repo_id '{{ sat_org }}' 'Red Hat Enterprise Linux Server' 'Red Hat Enterprise Linux 6 Server RPMs x86_64 6Server' )"
h 20-cv-create-all.log "content-view create --organization '{{ sat_org }}' --repository-ids '$rids' --name 'BenchContentView'"
h 21-cv-all-publish.log "content-view publish --organization '{{ sat_org }}' --name 'BenchContentView'"
h 22-cv-all-promote-1.log "content-view version promote --organization '{{ sat_org }}' --content-view 'BenchContentView' --to-lifecycle-environment 'Library' --to-lifecycle-environment 'BenchLifeEnvAAA'"
h 22-cv-all-promote-2.log "content-view version promote --organization '{{ sat_org }}' --content-view 'BenchContentView' --to-lifecycle-environment 'BenchLifeEnvAAA' --to-lifecycle-environment 'BenchLifeEnvBBB'"
h 22-cv-all-promote-3.log "content-view version promote --organization '{{ sat_org }}' --content-view 'BenchContentView' --to-lifecycle-environment 'BenchLifeEnvBBB' --to-lifecycle-environment 'BenchLifeEnvCCC'"


section "Publish and promote filtered CV"
rids="$( get_repo_id '{{ sat_org }}' 'Red Hat Enterprise Linux Server' 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server' )"
rids="$rids,$( get_repo_id '{{ sat_org }}' 'Red Hat Enterprise Linux Server' 'Red Hat Enterprise Linux 6 Server RPMs x86_64 6Server' )"
h 30-cv-create-filtered.log "content-view create --organization '{{ sat_org }}' --repository-ids '$rids' --name 'BenchFilteredContentView'"
h 31-filter-create-1.log "content-view filter create --organization '{{ sat_org }}' --type erratum --inclusion true --content-view BenchFilteredContentView --name BenchFilterAAA"
h 31-filter-create-2.log "content-view filter create --organization '{{ sat_org }}' --type erratum --inclusion true --content-view BenchFilteredContentView --name BenchFilterBBB"
h 32-rule-create-1.log "content-view filter rule create --content-view BenchFilteredContentView --content-view-filter BenchFilterAAA --date-type 'issued' --start-date 2016-01-01 --end-date 2017-10-01 --organization '{{ sat_org }}' --types enhancement,bugfix,security"
h 32-rule-create-2.log "content-view filter rule create --content-view BenchFilteredContentView --content-view-filter BenchFilterBBB --date-type 'updated' --start-date 2016-01-01 --end-date 2018-01-01 --organization '{{ sat_org }}' --types security"
h 33-cv-filtered-publish.log "content-view publish --organization '{{ sat_org }}' --name 'BenchFilteredContentView'"
h 34-cv-filtered-promote-1.log "content-view version promote --organization '{{ sat_org }}' --content-view 'BenchFilteredContentView' --to-lifecycle-environment 'Library' --to-lifecycle-environment 'BenchLifeEnvAAA'"
h 34-cv-filtered-promote-2.log "content-view version promote --organization '{{ sat_org }}' --content-view 'BenchFilteredContentView' --to-lifecycle-environment 'BenchLifeEnvAAA' --to-lifecycle-environment 'BenchLifeEnvBBB'"
h 34-cv-filtered-promote-3.log "content-view version promote --organization '{{ sat_org }}' --content-view 'BenchFilteredContentView' --to-lifecycle-environment 'BenchLifeEnvBBB' --to-lifecycle-environment 'BenchLifeEnvCCC'"


section "Publish and promote mixed content CV"
rids="$( get_repo_id '{{ sat_org }}' 'Red Hat Enterprise Linux Server' 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server' )"
rids="$rids,$( get_repo_id '{{ sat_org }}' 'Red Hat Enterprise Linux Server' 'Red Hat Enterprise Linux 6 Server RPMs x86_64 6Server' )"
rids="$rids,$( get_repo_id '{{ sat_org }}' 'BenchDockerHubProduct' 'RepoBusyboxAll' )"
rids="$rids,$( get_repo_id '{{ sat_org }}' 'BenchIsoProduct' 'Repofile-100k-100kB-A' )"
h 60-cv-create-mixed.log "content-view create --organization '{{ sat_org }}' --repository-ids '$rids' --name 'BenchMixedContentContentView'"
h 61-cv-mixed-publish.log "content-view publish --organization '{{ sat_org }}' --name 'BenchMixedContentContentView'"
h 62-cv-mixed-promote-1.log "content-view version promote --organization '{{ sat_org }}' --content-view 'BenchMixedContentContentView' --to-lifecycle-environment 'Library' --to-lifecycle-environment 'BenchLifeEnvAAA'"
h 62-cv-mixed-promote-2.log "content-view version promote --organization '{{ sat_org }}' --content-view 'BenchMixedContentContentView' --to-lifecycle-environment 'BenchLifeEnvAAA' --to-lifecycle-environment 'BenchLifeEnvBBB'"
h 62-cv-mixed-promote-3.log "content-view version promote --organization '{{ sat_org }}' --content-view 'BenchMixedContentContentView' --to-lifecycle-environment 'BenchLifeEnvBBB' --to-lifecycle-environment 'BenchLifeEnvCCC'"
