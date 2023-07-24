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
  || h rhel7sync-10-ensure-org.log "organization create --name '$organization'"
h_out "--no-headers --csv location list --fields name" | grep --quiet '^$dl$' \
  || h rhel7sync-10-ensure-loc-in-org.log "organization add-location --name '$organization' --location '$dl'"
a rhel7sync-10-manifest-deploy.log \
  -m copy \
  -a "src=$manifest dest=/root/manifest-auto.zip force=yes" satellite6
h rhel7sync-10-manifest-upload.log "subscription upload --file '/root/manifest-auto.zip' --organization '$organization'"
s $wait_interval


section "Sync from CDN mirror"
h rhel7sync-20-set-cdn-stage.log "organization update --name '$organization' --redhat-repository-url '$cdn_url_mirror'"

h rhel7sync-21-manifest-refresh.log "subscription refresh-manifest --organization '$organization'"

h rhel7sync-22-set-download-policy-immediate.log "settings set --organization '$organization' --name default_redhat_download_policy --value immediate"

# RHEL 7
h rhel7sync-23-reposet-enable-rhel7.log "repository-set enable --organization '$organization' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server (RPMs)' --releasever '7Server' --basearch 'x86_64'"
h rhel7sync-23-repo-sync-rhel7.log "repository synchronize --organization '$organization' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server'"


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


section "Sosreport"
skip_measurement='true' ap sosreporter-gatherer.log \
  -e "sosreport_gatherer_local_dir='../../$logs/sosreport/'" \
  playbooks/satellite/sosreport_gatherer.yaml


junit_upload
