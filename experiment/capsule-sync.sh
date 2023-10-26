#!/bin/bash

source experiment/run-library.sh

organization="${PARAM_organization:-Default Organization}"
manifest="${PARAM_manifest:-conf/contperf/manifest_SCA.zip}"
inventory="${PARAM_inventory:-conf/contperf/inventory.ini}"

cdn_url_full="${PARAM_cdn_url_full:-https://cdn.redhat.com/}"

repo_sat_client_6="${PARAM_repo_sat_client_6:-http://mirror.example.com/Satellite_Client_6_x86_64/}"
repo_sat_client_7="${PARAM_repo_sat_client_7:-http://mirror.example.com/Satellite_Client_7_x86_64/}"
repo_sat_client_8="${PARAM_repo_sat_client_8:-http://mirror.example.com/Satellite_Client_8_x86_64/}"
repo_sat_client_9="${PARAM_repo_sat_client_9:-http://mirror.example.com/Satellite_Client_9_x86_64/}"

lces="${PARAM_lces:-Test QA Pre Prod}"

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


section "Sync from CDN"
h capsync-20-set-cdn-stage.log "organization update --name '$organization' --redhat-repository-url '$cdn_url_full'"

h capsync-21-manifest-refresh.log "subscription refresh-manifest --organization '$organization'"

# RHEL 6
rel='rhel6'

h capsync-22-reposet-enable-${rel}.log "repository-set enable --organization '$organization' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 6 Server (RPMs)' --releasever '6Server' --basearch 'x86_64'"
h capsync-23-repo-sync-${rel}.log "repository synchronize --organization '$organization' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 6 Server RPMs x86_64 6Server'"

# RHEL 7
rel='rhel7'

h capsync-22-reposet-enable-${rel}.log "repository-set enable --organization '$organization' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server (RPMs)' --releasever '7Server' --basearch 'x86_64'"
h capsync-23-repo-sync-${rel}.log "repository synchronize --organization '$organization' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server'"

h capsync-22-reposet-enable-${rel}extras.log "repository-set enable --organization '$organization' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server - Extras (RPMs)' --releasever '7Server' --basearch 'x86_64'"
h capsync-23-repo-sync-${rel}extras.log "repository synchronize --organization '$organization' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server - Extras RPMs x86_64'"

# RHEL 8
rel='rhel8'

h capsync-22-reposet-enable-${rel}baseos.log "repository-set enable --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - BaseOS (RPMs)' --releasever '8' --basearch 'x86_64'"
h capsync-23-repo-sync-${rel}baseos.log "repository synchronize --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - BaseOS RPMs 8'"

h capsync-22-reposet-enable-${rel}appstream.log "repository-set enable --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - AppStream (RPMs)' --releasever '8' --basearch 'x86_64'"
h capsync-23-repo-sync-${rel}appstream.log "repository synchronize --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - AppStream RPMs 8'"

# RHEL 9
rel='rhel9'

h capsync-22-reposet-enable-${rel}baseos.log "repository-set enable --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 9 for x86_64 - BaseOS (RPMs)' --releasever '9' --basearch 'x86_64'"
h capsync-23-repo-sync-${rel}baseos.log "repository synchronize --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 9 for x86_64 - BaseOS RPMs 9'"

h capsync-22-reposet-enable-${rel}appstream.log "repository-set enable --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 9 for x86_64 - AppStream (RPMs)' --releasever '9' --basearch 'x86_64'"
h capsync-23-repo-sync-${rel}appstream.log "repository synchronize --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 9 for x86_64 - AppStream RPMs 9'"


section "Sync Satellite Client repos"
h capsync-27-client-product-create.log "product create --organization '$organization' --name SatClientProduct"

# Satellite Client for RHEL 6
h capsync-28-repository-create-sat-client_6.log "repository create --organization '$organization' --product SatClientProduct --name SatClient6Repo --content-type yum --url '$repo_sat_client_6'"
h capsync-29-repository-sync-sat-client_6.log "repository synchronize --organization '$organization' --product SatClientProduct --name SatClient6Repo"

# Satellite Client for RHEL 7
h capsync-28-repository-create-sat-client_7.log "repository create --organization '$organization' --product SatClientProduct --name SatClient7Repo --content-type yum --url '$repo_sat_client_7'"
h capsync-29-repository-sync-sat-client_7.log "repository synchronize --organization '$organization' --product SatClientProduct --name SatClient7Repo"

# Satellite Client for RHEL 8
h capsync-28-repository-create-sat-client_8.log "repository create --organization '$organization' --product SatClientProduct --name SatClient8Repo --content-type yum --url '$repo_sat_client_8'"
h capsync-29-repository-sync-sat-client_8.log "repository synchronize --organization '$organization' --product SatClientProduct --name SatClient8Repo"

# Satellite Client for RHEL 9
h capsync-28-repository-create-sat-client_9.log "repository create --organization '$organization' --product SatClientProduct --name SatClient9Repo --content-type yum --url '$repo_sat_client_9'"
h capsync-29-repository-sync-sat-client_9.log "repository synchronize --organization '$organization' --product SatClientProduct --name SatClient9Repo"


section "Create LCEs"
prior='Library'
for lce in $lces; do
    h capsync-30-${lce}-lce-create.log "lifecycle-environment create --organization '$organization' --prior '$prior' --name '$lce'"
    prior="${lce}"
done


section "Create, publish and promote Operating System related content"
# RHEL 6
rel='rhel6'
cv="CV_$rel"
rids="$( get_repo_id 'Red Hat Enterprise Linux Server' 'Red Hat Enterprise Linux 6 Server RPMs x86_64 6Server' )"

h capsync-31-${rel}-cv-create.log "content-view create --organization '$organization' --repository-ids '$rids' --name '$cv'"
h capsync-32-${rel}-cv-publish.log "content-view publish --organization '$organization' --name '$cv'"

tmp="$( mktemp )"
h_out "--no-headers --csv content-view version list --organization '$organization' --content-view '$cv'" | grep '^[0-9]\+,' >$tmp
version="$( head -n1 $tmp | cut -d ',' -f 3 | tr '\n' ',' | sed 's/,$//' )"
rm -f $tmp
prior='Library'
for lce in $lces; do
    h capsync-33-${rel}-${lce}-lce-promote.log "content-view version promote --organization '$organization' --content-view '$cv' --version '$version' --from-lifecycle-environment '$prior' --to-lifecycle-environment '$lce'"
    prior="${lce}"
done

# RHEL 7
rel='rhel7'
cv="CV_$rel"
rids="$( get_repo_id 'Red Hat Enterprise Linux Server' 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server' )"
rids="$rids,$( get_repo_id 'Red Hat Enterprise Linux Server' 'Red Hat Enterprise Linux 7 Server - Extras RPMs x86_64' )"

h capsync-31-${rel}-cv-create.log "content-view create --organization '$organization' --repository-ids '$rids' --name '$cv'"
h capsync-32-${rel}-cv-publish.log "content-view publish --organization '$organization' --name '$cv'"

tmp="$( mktemp )"
h_out "--no-headers --csv content-view version list --organization '$organization' --content-view '$cv'" | grep '^[0-9]\+,' >$tmp
version="$( head -n1 $tmp | cut -d ',' -f 3 | tr '\n' ',' | sed 's/,$//' )"
rm -f $tmp
prior='Library'
for lce in $lces; do
    h capsync-33-${rel}-${lce}-lce-promote.log "content-view version promote --organization '$organization' --content-view '$cv' --version '$version' --from-lifecycle-environment '$prior' --to-lifecycle-environment '$lce'"
    prior="${lce}"
done

# RHEL 8
rel='rhel8'
cv="CV_$rel"
rids="$( get_repo_id 'Red Hat Enterprise Linux for x86_64' 'Red Hat Enterprise Linux 8 for x86_64 - BaseOS RPMs 8' )"
rids="$rids,$( get_repo_id 'Red Hat Enterprise Linux for x86_64' 'Red Hat Enterprise Linux 8 for x86_64 - AppStream RPMs 8' )"

h capsync-31-${rel}-cv-create.log "content-view create --organization '$organization' --repository-ids '$rids' --name '$cv'"
h capsync-32-${rel}-cv-publish.log "content-view publish --organization '$organization' --name '$cv'"

tmp="$( mktemp )"
h_out "--no-headers --csv content-view version list --organization '$organization' --content-view '$cv'" | grep '^[0-9]\+,' >$tmp
version="$( head -n1 $tmp | cut -d ',' -f 3 | tr '\n' ',' | sed 's/,$//' )"
rm -f $tmp
prior='Library'
for lce in $lces; do
    h capsync-33-${rel}-${lce}-lce-promote.log "content-view version promote --organization '$organization' --content-view '$cv' --version '$version' --from-lifecycle-environment '$prior' --to-lifecycle-environment '$lce'"
    prior="${lce}"
done

# RHEL 9
rel='rhel9'
cv="CV_$rel"
rids="$( get_repo_id 'Red Hat Enterprise Linux for x86_64' 'Red Hat Enterprise Linux 9 for x86_64 - BaseOS RPMs 9' )"
rids="$rids,$( get_repo_id 'Red Hat Enterprise Linux for x86_64' 'Red Hat Enterprise Linux 9 for x86_64 - AppStream RPMs 9' )"

h capsync-31-${rel}-cv-create.log "content-view create --organization '$organization' --repository-ids '$rids' --name '$cv'"
h capsync-32-${rel}-cv-publish.log "content-view publish --organization '$organization' --name '$cv'"

tmp="$( mktemp )"
h_out "--no-headers --csv content-view version list --organization '$organization' --content-view '$cv'" | grep '^[0-9]\+,' >$tmp
version="$( head -n1 $tmp | cut -d ',' -f 3 | tr '\n' ',' | sed 's/,$//' )"
rm -f $tmp
prior='Library'
for lce in $lces; do
    h capsync-33-${rel}-${lce}-lce-promote.log "content-view version promote --organization '$organization' --content-view '$cv' --version '$version' --from-lifecycle-environment '$prior' --to-lifecycle-environment '$lce'"
    prior="${lce}"
done


section "Add, publish and promote Satellite Client related content"
# RHEL 6
rel='rhel6'
cv="CV_$rel"
rid="$( get_repo_id 'SatClientProduct' 'SatClient6Repo' )"

h capsync-34-${rel}-cv-add-repository.log "content-view add-repository --organization '$organization' --repository-id '$rid' --name '$cv'"
h capsync-35-${rel}-cv-republish.log "content-view publish --organization '$organization' --name '$cv'"

tmp="$( mktemp )"
h_out "--no-headers --csv content-view version list --organization '$organization' --content-view '$cv'" | grep '^[0-9]\+,' >$tmp
version="$( head -n1 $tmp | cut -d ',' -f 3 | tr '\n' ',' | sed 's/,$//' )"
rm -f $tmp
prior='Library'
for lce in $lces; do
    h capsync-36-${rel}-${lce}-lce-promote.log "content-view version promote --organization '$organization' --content-view '$cv' --version '$version' --from-lifecycle-environment '$prior' --to-lifecycle-environment '$lce'"
    prior="${lce}"
done

# RHEL 7
rel='rhel7'
cv="CV_$rel"
rid="$( get_repo_id 'SatClientProduct' 'SatClient7Repo' )"

h capsync-34-${rel}-cv-add-repository.log "content-view add-repository --organization '$organization' --repository-id '$rid' --name '$cv'"
h capsync-35-${rel}-cv-republish.log "content-view publish --organization '$organization' --name '$cv'"

tmp="$( mktemp )"
h_out "--no-headers --csv content-view version list --organization '$organization' --content-view '$cv'" | grep '^[0-9]\+,' >$tmp
version="$( head -n1 $tmp | cut -d ',' -f 3 | tr '\n' ',' | sed 's/,$//' )"
rm -f $tmp
prior='Library'
for lce in $lces; do
    h capsync-36-${rel}-${lce}-lce-promote.log "content-view version promote --organization '$organization' --content-view '$cv' --version '$version' --from-lifecycle-environment '$prior' --to-lifecycle-environment '$lce'"
    prior="${lce}"
done

# RHEL 8
rel='rhel8'
cv="CV_$rel"
rid="$( get_repo_id 'SatClientProduct' 'SatClient8Repo' )"

h capsync-34-${rel}-cv-add-repository.log "content-view add-repository --organization '$organization' --repository-id '$rid' --name '$cv'"
h capsync-35-${rel}-cv-republish.log "content-view publish --organization '$organization' --name '$cv'"

tmp="$( mktemp )"
h_out "--no-headers --csv content-view version list --organization '$organization' --content-view '$cv'" | grep '^[0-9]\+,' >$tmp
version="$( head -n1 $tmp | cut -d ',' -f 3 | tr '\n' ',' | sed 's/,$//' )"
rm -f $tmp
prior='Library'
for lce in $lces; do
    h capsync-36-${rel}-${lce}-lce-promote.log "content-view version promote --organization '$organization' --content-view '$cv' --version '$version' --from-lifecycle-environment '$prior' --to-lifecycle-environment '$lce'"
    prior="${lce}"
done

# RHEL 9
rel='rhel9'
cv="CV_$rel"
rid="$( get_repo_id 'SatClientProduct' 'SatClient9Repo' )"

h capsync-34-${rel}-cv-add-repository.log "content-view add-repository --organization '$organization' --repository-id '$rid' --name '$cv'"
h capsync-35-${rel}-cv-republish.log "content-view publish --organization '$organization' --name '$cv'"

tmp="$( mktemp )"
h_out "--no-headers --csv content-view version list --organization '$organization' --content-view '$cv'" | grep '^[0-9]\+,' >$tmp
version="$( head -n1 $tmp | cut -d ',' -f 3 | tr '\n' ',' | sed 's/,$//' )"
rm -f $tmp
prior='Library'
for lce in $lces; do
    h capsync-36-${rel}-${lce}-lce-promote.log "content-view version promote --organization '$organization' --content-view '$cv' --version '$version' --from-lifecycle-environment '$prior' --to-lifecycle-environment '$lce'"
    prior="${lce}"
done


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
          -e "lces='$lces'" \
          -e "num_concurrent_capsules='$num_concurrent_capsules'" \
          playbooks/satellite/capsules-populate.yaml
    fi
done


section "Sosreport"
skip_measurement='true' ap sosreporter-gatherer.log \
  -e "sosreport_gatherer_local_dir='../../$logs/sosreport/'" \
  playbooks/satellite/sosreport_gatherer.yaml


junit_upload
