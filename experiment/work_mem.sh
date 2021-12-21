#!/bin/sh

source experiment/run-library.sh

manifest="${PARAM_manifest:-conf/contperf/manifest.zip}"
inventory="${PARAM_inventory:-conf/contperf/inventory.ini}"
private_key="${PARAM_private_key:-conf/contperf/id_rsa_perf}"

wait_interval=${PARAM_wait_interval:-50}

cdn_url_mirror="${PARAM_cdn_url_mirror:-https://cdn.redhat.com/}"

work_mem_value="${PARAM_test_work_mem_value:-4MB}"

do="Default Organization"
dl="Default Location"

opts="--forks 100 -i $inventory --private-key $private_key"
opts_adhoc="$opts --user root -e @conf/satperf.yaml -e @conf/satperf.local.yaml"

section "Configure for work_mem"
skip_measurement='true' a 00-configure-work_mem-lineinfile.log satellite6,capsules -u root -m lineinfile -a "path='/var/opt/rh/rh-postgresql12/lib/pgsql/data/postgresql.conf' regexp='^work_mem\s*=' line='work_mem = $work_mem_value'"
a 01-configure-work_mem-restart.log satellite6,capsules -u root -m command -a 'satellite-maintain service restart'

section "Checking environment for work_mem"
generic_environment_check false

section "Setup for work_mem"
ORG="test-work_mem-$RANDOM"
LOCS_CAPSULE="$( h_out "--output csv --no-headers location list --fields title" | grep -v 'rc=' | tr "\n" "," | sed 's/,$//' )"
h 10-create-org.log "organization create --name $ORG --locations '$LOCS_CAPSULE'"
h 11-create-le1.log "lifecycle-environment create --name $ORG-le1 --prior Library --organization $ORG"
a 12-upload-cert-file.log satellite6 -u root -m copy -a "src='$manifest' dest=/root/manifest.zip"
h 13-upload-cert.log "subscription upload --organization $ORG --file /root/manifest.zip"
h 14-set-local-cdn-mirror.log "organization update --name '$ORG' --redhat-repository-url '$cdn_url_mirror'"
h 15-reposet-enable-rhel6.log "repository-set enable --organization '$ORG' --name 'Red Hat Enterprise Linux 6 Server (RPMs)' --releasever '6Server' --basearch 'x86_64'"
h 15-reposet-enable-rhel7.log "repository-set enable --organization '$ORG' --name 'Red Hat Enterprise Linux 7 Server (RPMs)' --releasever '7Server' --basearch 'x86_64'"
h 15-reposet-enable-rhel8-b.log "repository-set enable --organization '$ORG' --name 'Red Hat Enterprise Linux 8 for x86_64 - BaseOS (RPMs)' --basearch x86_64 --releasever 8"
h 15-reposet-enable-rhel8-a.log "repository-set enable --organization '$ORG' --name 'Red Hat Enterprise Linux 8 for x86_64 - AppStream (RPMs)' --basearch x86_64 --releasever 8"

section "Sync for work_mem"
h 20-repo-sync-rhel6-validated.log "repository synchronize --organization '$ORG' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 6 Server RPMs x86_64 6Server' --validate-contents true" &
h 20-repo-sync-rhel7-validated.log "repository synchronize --organization '$ORG' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server' --validate-contents true" &
h 20-repo-sync-rhel8-b-validated.log "repository synchronize --organization '$ORG' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - BaseOS RPMs 8' --validate-contents true" &
h 20-repo-sync-rhel8-b-validated.log "repository synchronize --organization '$ORG' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - AppStream RPMs 8' --validate-contents true" &
wait
s $wait_interval
h 21-repo-sync-rhel6-nonvalidated.log "repository synchronize --organization '$ORG' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 6 Server RPMs x86_64 6Server' --validate-contents false" &
h 21-repo-sync-rhel7-nonvalidated.log "repository synchronize --organization '$ORG' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server' --validate-contents false" &
h 21-repo-sync-rhel8-b-nonvalidated.log "repository synchronize --organization '$ORG' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - BaseOS RPMs 8' --validate-contents false" &
h 21-repo-sync-rhel8-b-nonvalidated.log "repository synchronize --organization '$ORG' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - AppStream RPMs 8' --validate-contents false" &
wait

section "Content views for work_mem"
function get_id() {
    h_out "--output csv --no-headers repository list --organization '$1'" | grep "^[0-9]\+,$2," | cut -d ',' -f 1
}
rhel6=$( get_id "$ORG" "Red Hat Enterprise Linux 6 Server RPMs x86_64 6Server" )
rhel7=$( get_id "$ORG" "Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server" )
rhel8_baseos=$( get_id "$ORG" "Red Hat Enterprise Linux 8 for x86_64 - BaseOS RPMs 8" )
rhel8_appstream=$( get_id "$ORG" "Red Hat Enterprise Linux 8 for x86_64 - AppStream RPMs 8" )
h 30-create-cv-big.log "content-view create --auto-publish false --name $ORG-cv-big --repository-ids '$rhel6,$rhel7,$rhel8_baseos,$rhel8_appstream' --organization $ORG --solve-dependencies true"
h 31-publish-cv-big.log "content-view publish --name $ORG-cv-big --organization $ORG"
h 32-promote-cvv-big.log "content-view version promote --content-view $ORG-cv-big --from-lifecycle-environment Library --to-lifecycle-environment $ORG-le1 --organization $ORG"

section "Excercise packages API for work_mem"
h 40-package-list-page.log "package list --content-view $ORG-cv-big --lifecycle-environment $ORG-le1 --organization $ORG --page 2 --per-page 1000"
h_drop 41-package-list-all.log "package list --content-view $ORG-cv-big --lifecycle-environment $ORG-le1 --organization $ORG --full-result true"

section "Cleanup for work_mem"
h 50-delete-org.log "organization delete --name $ORG"


junit_upload
