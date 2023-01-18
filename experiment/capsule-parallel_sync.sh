#!/bin/bash

source experiment/run-library.sh

organization="${PARAM_organization:-Default Organization}"
manifest="${PARAM_manifest:-conf/contperf/manifest_SCA.zip}"
inventory="${PARAM_inventory:-conf/contperf/inventory.ini}"

wait_interval=${PARAM_wait_interval:-30}

cdn_url_mirror="${PARAM_cdn_url_mirror:-https://cdn.redhat.com/}"

rhel_subscription="${PARAM_rhel_subscription:-Red Hat Enterprise Linux Server, Standard (Physical or Virtual Nodes)}"

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
a capsync-10-manifest-deploy.log -m copy -a "src=$manifest dest=/root/manifest-auto.zip force=yes" satellite6
h capsync-10-manifest-upload.log "subscription upload --file '/root/manifest-auto.zip' --organization '$organization'"
s $wait_interval


section "Sync from CDN mirror"
h capsync-20-set-cdn-stage.log "organization update --name '$organization' --redhat-repository-url '$cdn_url_mirror'"

h capsync-21-manifest-refresh.log "subscription refresh-manifest --organization '$organization'"

h capsync-22-set-download-policy-immediate.log "settings set --organization '$organization' --name default_redhat_download_policy --value immediate"

h capsync-23-reposet-enable-rhel7.log "repository-set enable --organization '$organization' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server (RPMs)' --releasever '7Server' --basearch 'x86_64'"
h capsync-23-repo-sync-rhel7.log "repository synchronize --organization '$organization' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server'"

h capsync-24-reposet-enable-rhel7extras.log "repository-set enable --organization '$organization' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server - Extras (RPMs)' --releasever '7Server' --basearch 'x86_64'"
h capsync-24-repo-sync-rhel7extras.log "repository synchronize --organization '$organization' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server - Extras RPMs x86_64'"

h capsync-25-reposet-enable-rhel8baseos.log "repository-set enable --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - BaseOS (RPMs)' --releasever '8' --basearch 'x86_64'"
h capsync-25-repo-sync-rhel8baseos.log "repository synchronize --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - BaseOS RPMs 8'"

h capsync-26-reposet-enable-rhel8appstream.log "repository-set enable --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - AppStream (RPMs)' --releasever '8' --basearch 'x86_64'"
h capsync-26-repo-sync-rhel8appstream.log "repository synchronize --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - AppStream RPMs 8'"

h capsync-25-reposet-enable-rhel9baseos.log "repository-set enable --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 9 for x86_64 - BaseOS (RPMs)' --releasever '9' --basearch 'x86_64'"
h capsync-25-repo-sync-rhel9baseos.log "repository synchronize --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 9 for x86_64 - BaseOS RPMs 9'"

h capsync-26-reposet-enable-rhel9appstream.log "repository-set enable --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 9 for x86_64 - AppStream (RPMs)' --releasever '9' --basearch 'x86_64'"
h capsync-26-repo-sync-rhel9appstream.log "repository synchronize --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 9 for x86_64 - AppStream RPMs 9'"
s $wait_interval


export skip_measurement='true'
section "Prepare content"
h capsync-30-ak-create.log "activation-key create --content-view '$organization View' --lifecycle-environment Library --name ActivationKey --organization '$organization'"

h_out "--csv subscription list --organization '$organization' --search 'name = \"$rhel_subscription\"'" >$logs/subs-list-rhel.log
rhel_subs_id=$( tail -n 1 $logs/subs-list-rhel.log | cut -d ',' -f 1 )
h capsync-31-ak-add-subs-rhel.log "activation-key add-subscription --organization '$organization' --name ActivationKey --subscription-id '$rhel_subs_id'"
s $wait_interval
unset skip_measurement


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
    ap capsync-40-populate-${iter}.log playbooks/satellite/capsules-populate.yaml -e "organization='$organization'" -e "num_concurrent_capsules='$num_concurrent_capsules'" --limit capsules["$limit"]
    s $wait_interval
  fi
done


section "Sosreport"
skip_measurement='true' ap sosreporter-gatherer.log playbooks/satellite/sosreport_gatherer.yaml -e "sosreport_gatherer_local_dir='../../$logs/sosreport/'"


junit_upload
