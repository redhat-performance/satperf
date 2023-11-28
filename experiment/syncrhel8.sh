#!/bin/bash

source experiment/run-library.sh

branch="${PARAM_branch:-satcpt}"
inventory="${PARAM_inventory:-conf/contperf/inventory.${branch}.ini}"

cdn_url_mirror="${PARAM_cdn_url_mirror:-https://cdn.redhat.com/}"

rhel_subscription="${PARAM_rhel_subscription:-Red Hat Enterprise Linux Server, Standard (Physical or Virtual Nodes)}"

dl='Default Location'

opts="--forks 100 -i $inventory"
opts_adhoc="$opts -e branch='$branch'"


section "Checking environment"
generic_environment_check


section "Upload manifest"
h_out "--no-headers --csv organization list --fields name" | grep --quiet "^{{ sat_org }}$" \
  || h rhel8sync-10-ensure-org.log "organization create --name '{{ sat_org }}'"
h_out "--no-headers --csv location list --fields name" | grep --quiet '^$dl$' \
  || h rhel8sync-10-ensure-loc-in-org.log "organization add-location --name '{{ sat_org }}' --location '$dl'"
a rhel8sync-10-manifest-deploy.log \
  -m copy \
  -a "src=$manifest dest=/root/manifest-auto.zip force=yes" satellite6
h rhel8sync-10-manifest-upload.log "subscription upload --file '/root/manifest-auto.zip' --organization '{{ sat_org }}'"


section "Sync from CDN mirror"
h rhel8sync-20-set-cdn-stage.log "organization update --name '{{ sat_org }}' --redhat-repository-url '$cdn_url_mirror'"

h rhel8sync-21-manifest-refresh.log "subscription refresh-manifest --organization '{{ sat_org }}'"

#h rhel8sync-22-set-download-policy-immediate.log "settings set --organization '{{ sat_org }}' --name default_redhat_download_policy --value immediate"
#h rhel8sync-22-set-download-policy-streamed.log "settings set --organization '{{ sat_org }}' --name default_redhat_download_policy --value streamed"
h rhel8sync-22-set-download-policy-on_demand.log "settings set --organization '{{ sat_org }}' --name default_redhat_download_policy --value on_demand"

# EPEL 8 download
a rhel8sync-28-download-epel-8-gpg-key.log satellite6 \
  -m command \
  -a "curl -O -L https://dl.fedoraproject.org/pub/epel/RPM-GPG-KEY-EPEL-8"
h rhel8sync-28-content-credentials-create-epel-8.log "content-credentials create --organization '{{ sat_org }}' --content-type gpg_key --name 'RPM_GPG_KEY_EPEL_8' --path ~/RPM-GPG-KEY-EPEL-8"

h rhel8sync-28-product-create-epel-8.log "product create --organization '{{ sat_org }}' --name 'EPEL 8' --gpg-key-id 1"

h rhel8sync-28-repo-create-epel-8.log "repository create --organization '{{ sat_org }}'  --product 'EPEL 8' --name 'EPEL 8 for x86_64 - Everything RPMs 8' --content-type 'yum' --download-policy 'on_demand' --url 'https://dl.fedoraproject.org/pub/epel/8/Everything/x86_64'"

# RHEL 8
h rhel8sync-25-reposet-enable-rhel8baseos.log "repository-set enable --organization '{{ sat_org }}' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - BaseOS (RPMs)' --releasever '8' --basearch 'x86_64'"
h rhel8sync-26-reposet-enable-rhel8appstream.log "repository-set enable --organization '{{ sat_org }}' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - AppStream (RPMs)' --releasever '8' --basearch 'x86_64'"

h rhel8sync-25-repo-sync-rhel8baseos.log "repository synchronize --organization '{{ sat_org }}' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - BaseOS RPMs 8'" &
h rhel8sync-26-repo-sync-rhel8appstream.log "repository synchronize --organization '{{ sat_org }}' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - AppStream RPMs 8'" &

#epel 8
h rhel8sync-28-repo-sync-epel-8.log "repository synchronize --organization '{{ sat_org }}' --product 'EPEL 8' --name 'EPEL 8 for x86_64 - Everything RPMs 8'" &


section "Create, publish and promote CVs / LCEs"
# RHEL 8
rids="$( get_repo_id 'Red Hat Enterprise Linux for x86_64' 'Red Hat Enterprise Linux 8 for x86_64 - BaseOS RPMs 8' )"
rids="$rids,$( get_repo_id 'Red Hat Enterprise Linux for x86_64' 'Red Hat Enterprise Linux 8 for x86_64 - AppStream RPMs 8' )"
rids="$rids,$( get_repo_id 'EPEL 8' 'EPEL 8 for x86_64 - Everything RPMs 8' )"
cv='CV_RHEL8'
lce='LCE_RHEL8'
lces+=",$lce"

skip_measurement='true' h 30-rhel8-cv-create.log "content-view create --organization '{{ sat_org }}' --repository-ids '$rids' --name '$cv'"
h 31-rhel8-cv-publish.log "content-view publish --organization '{{ sat_org }}' --name '$cv'"

skip_measurement='true' h 35-rhel8-lce-create.log "lifecycle-environment create --organization '{{ sat_org }}' --prior 'Library' --name '$lce'"
h 36-rhel8-lce-promote.log "content-view version promote --organization '{{ sat_org }}' --content-view '$cv' --to-lifecycle-environment 'Library' --to-lifecycle-environment '$lce'"

section "Sosreport"
skip_measurement='true' ap sosreporter-gatherer.log \
  -e "sosreport_gatherer_local_dir='../../$logs/sosreport/'" \
  playbooks/satellite/sosreport_gatherer.yaml


junit_upload
