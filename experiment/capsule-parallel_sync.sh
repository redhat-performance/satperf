#!/bin/bash

source experiment/run-library.sh

organization="${PARAM_organization:-Default Organization}"
manifest="${PARAM_manifest:-conf/contperf/manifest_SCA.zip}"
inventory="${PARAM_inventory:-conf/contperf/inventory.ini}"

wait_interval=${PARAM_wait_interval:-30}

cdn_url_mirror="${PARAM_cdn_url_mirror:-https://cdn.redhat.com/}"

rhel_subscription="${PARAM_rhel_subscription:-Red Hat Enterprise Linux Server, Standard (Physical or Virtual Nodes)}"

repo_sat_client_7="${PARAM_repo_sat_client_7:-http://mirror.example.com/Satellite_Client_7_x86_64/}"
repo_sat_client_8="${PARAM_repo_sat_client_8:-http://mirror.example.com/Satellite_Client_8_x86_64/}"
repo_sat_client_9="${PARAM_repo_sat_client_9:-http://mirror.example.com/Satellite_Client_9_x86_64/}"

initial_index="${PARAM_initial_index:-0}"

dl='Default Location'

opts="--forks 100 -i $inventory"
opts_adhoc="$opts"


section "Checking environment"
generic_environment_check


section "Upload manifest"
h_out "--no-headers --csv organization list --fields name" | grep --quiet "^$organization$" \
  || h capsync-10-ensure-org.log "organization create --name '$organization'"
h_out "--no-headers --csv location list --fields name" | grep --quiet '^$dl$' \
  || h capsync-10-ensure-loc-in-org.log "organization add-location --name '$organization' --location '$dl'"
a capsync-10-manifest-deploy.log \
  -m copy \
  -a "src=$manifest dest=/root/manifest-auto.zip force=yes" satellite6
h capsync-10-manifest-upload.log "subscription upload --file '/root/manifest-auto.zip' --organization '$organization'"
s $wait_interval


section "Sync from CDN mirror"
h capsync-20-set-cdn-stage.log "organization update --name '$organization' --redhat-repository-url '$cdn_url_mirror'"

h capsync-21-manifest-refresh.log "subscription refresh-manifest --organization '$organization'"

h capsync-22-set-download-policy-immediate.log "settings set --organization '$organization' --name default_redhat_download_policy --value immediate"

# RHEL 7
h capsync-23-reposet-enable-rhel7.log "repository-set enable --organization '$organization' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server (RPMs)' --releasever '7Server' --basearch 'x86_64'"
h capsync-23-repo-sync-rhel7.log "repository synchronize --organization '$organization' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server'"

h capsync-24-reposet-enable-rhel7extras.log "repository-set enable --organization '$organization' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server - Extras (RPMs)' --releasever '7Server' --basearch 'x86_64'"
h capsync-24-repo-sync-rhel7extras.log "repository synchronize --organization '$organization' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server - Extras RPMs x86_64'"

# RHEL 8
h capsync-25-reposet-enable-rhel8baseos.log "repository-set enable --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - BaseOS (RPMs)' --releasever '8' --basearch 'x86_64'"
h capsync-25-repo-sync-rhel8baseos.log "repository synchronize --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - BaseOS RPMs 8'"

h capsync-26-reposet-enable-rhel8appstream.log "repository-set enable --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - AppStream (RPMs)' --releasever '8' --basearch 'x86_64'"
h capsync-26-repo-sync-rhel8appstream.log "repository synchronize --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - AppStream RPMs 8'"

# RHEL 9
h capsync-25-reposet-enable-rhel9baseos.log "repository-set enable --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 9 for x86_64 - BaseOS (RPMs)' --releasever '9' --basearch 'x86_64'"
h capsync-25-repo-sync-rhel9baseos.log "repository synchronize --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 9 for x86_64 - BaseOS RPMs 9'"

h capsync-26-reposet-enable-rhel9appstream.log "repository-set enable --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 9 for x86_64 - AppStream (RPMs)' --releasever '9' --basearch 'x86_64'"
h capsync-26-repo-sync-rhel9appstream.log "repository synchronize --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 9 for x86_64 - AppStream RPMs 9'"
s $wait_interval


export skip_measurement='true'
section "Sync Satellite Client repos"
h capsync-28-client-product-create.log "product create --organization '$organization' --name SatClientProduct"

# Satellite Client for RHEL 7
h capsync-29-repository-create-sat-client_7.log "repository create --organization '$organization' --product SatClientProduct --name SatClient7Repo --content-type yum --url '$repo_sat_client_7'"
h capsync-29-repository-sync-sat-client_7.log "repository synchronize --organization '$organization' --product SatClientProduct --name SatClient7Repo"

# Satellite Client for RHEL 8
h capsync-29-repository-create-sat-client_8.log "repository create --organization '$organization' --product SatClientProduct --name SatClient8Repo --content-type yum --url '$repo_sat_client_8'"
h capsync-29-repository-sync-sat-client_8.log "repository synchronize --organization '$organization' --product SatClientProduct --name SatClient8Repo"

# Satellite Client for RHEL 9
h capsync-29-repository-create-sat-client_9.log "repository create --organization '$organization' --product SatClientProduct --name SatClient9Repo --content-type yum --url '$repo_sat_client_9'"
h capsync-29-repository-sync-sat-client_9.log "repository synchronize --organization '$organization' --product SatClientProduct --name SatClient9Repo"
s $wait_interval
unset skip_measurement


section "Create, publish and promote CVs / LCEs"
# RHEL 7
rids="$( get_repo_id 'Red Hat Enterprise Linux Server' 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server' )"
rids="$rids,$( get_repo_id 'Red Hat Enterprise Linux Server' 'Red Hat Enterprise Linux 7 Server - Extras RPMs x86_64' )"
rids="$rids,$( get_repo_id 'SatClientProduct' 'SatClient7Repo' )"
cv='CV_RHEL7'
lce='LCE_RHEL7'
lces='$lce'

skip_measurement='true' h 30-rhel7-cv-create.log "content-view create --organization '$organization' --repository-ids '$rids' --name '$cv'"
h 31-rhel7-cv-publish.log "content-view publish --organization '$organization' --name '$cv'"

skip_measurement='true' h 35-rhel7-lce-create.log "lifecycle-environment create --organization '$organization' --prior 'Library' --name '$lce'"
h 36-rhel7-lce-promote.log "content-view version promote --organization '$organization' --content-view '$cv' --to-lifecycle-environment 'Library' --to-lifecycle-environment '$lce'"

# RHEL 8
rids="$( get_repo_id 'Red Hat Enterprise Linux for x86_64' 'Red Hat Enterprise Linux 8 for x86_64 - BaseOS RPMs 8' )"
rids="$rids,$( get_repo_id 'Red Hat Enterprise Linux for x86_64' 'Red Hat Enterprise Linux 8 for x86_64 - AppStream RPMs 8' )"
rids="$rids,$( get_repo_id 'SatClientProduct' 'SatClient8Repo' )"
cv='CV_RHEL8'
lce='LCE_RHEL8'
lces+=",$lce"

skip_measurement='true' h 30-rhel8-cv-create.log "content-view create --organization '$organization' --repository-ids '$rids' --name '$cv'"
h 31-rhel8-cv-publish.log "content-view publish --organization '$organization' --name '$cv'"

skip_measurement='true' h 35-rhel8-lce-create.log "lifecycle-environment create --organization '$organization' --prior 'Library' --name '$lce'"
h 36-rhel8-lce-promote.log "content-view version promote --organization '$organization' --content-view '$cv' --to-lifecycle-environment 'Library' --to-lifecycle-environment '$lce'"

# RHEL 9
rids="$( get_repo_id 'Red Hat Enterprise Linux for x86_64' 'Red Hat Enterprise Linux 9 for x86_64 - BaseOS RPMs 9' )"
rids="$rids,$( get_repo_id 'Red Hat Enterprise Linux for x86_64' 'Red Hat Enterprise Linux 9 for x86_64 - AppStream RPMs 9' )"
rids="$rids,$( get_repo_id 'SatClientProduct' 'SatClient9Repo' )"
cv='CV_RHEL9'
lce='LCE_RHEL9'
lces+=",$lce"

skip_measurement='true' h 30-rhel9-cv-create.log "content-view create --organization '$organization' --repository-ids '$rids' --name '$cv'"
h 31-rhel9-cv-publish.log "content-view publish --organization '$organization' --name '$cv'"

skip_measurement='true' h 35-rhel9-lce-create.log "lifecycle-environment create --organization '$organization' --prior 'Library' --name '$lce'"
h 36-rhel9-lce-promote.log "content-view version promote --organization '$organization' --content-view '$cv' --to-lifecycle-environment 'Library' --to-lifecycle-environment '$lce'"
s $wait_interval


section "Push content to capsules"
num_capsules="$(ansible -i $inventory --list-hosts capsules 2>/dev/null | grep -vc '^  hosts ')"

for (( iter=0, last=-1; last < (num_capsules - 1); iter++ )); do
    if (( initial_index == 0 && iter == 0 )); then
        continue
    else
        first="$(( last + 1 ))"
        incr="$(( initial_index + iter - 1 ))"
        last="$(( first + incr ))"
        if (( last >= num_capsules )); then
            last="$(( num_capsules - 1 ))"
        fi
        limit="${first}:${last}"
        num_concurrent_capsules="$(( last - first + 1 ))"
        ap capsync-40-populate-${iter}.log \
          --limit capsules["$limit"] \
          -e "organization='$organization'" \
          -e "download_policy='immediate'" \
          -e "lces='$lces'" \
          -e "num_concurrent_capsules='$num_concurrent_capsules'" \
          playbooks/satellite/capsules-populate.yaml
        s $wait_interval
    fi
done


section "Sosreport"
skip_measurement='true' ap sosreporter-gatherer.log \
  -e "sosreport_gatherer_local_dir='../../$logs/sosreport/'" \
  playbooks/satellite/sosreport_gatherer.yaml


junit_upload
