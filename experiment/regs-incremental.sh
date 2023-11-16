#!/bin/bash

source experiment/run-library.sh

organization="${PARAM_organization:-Default Organization}"
manifest="${PARAM_manifest:-conf/contperf/manifest_SCA.zip}"
inventory="${PARAM_inventory:-conf/contperf/inventory.ini}"
local_conf="${PARAM_local_conf:-conf/satperf.local.yaml}"

wait_interval=${PARAM_wait_interval:-10}

cdn_url_full="${PARAM_cdn_url_full:-https://cdn.redhat.com/}"

repo_sat_client_8="${PARAM_repo_sat_client_8:-http://mirror.example.com/Satellite_Client_8_x86_64/}"

rhel_subscription="${PARAM_rhel_subscription:-Red Hat Enterprise Linux Server, Standard (Physical or Virtual Nodes)}"

initial_expected_concurrent_registrations="${PARAM_initial_expected_concurrent_registrations:-25}"

dl="Default Location"

opts="--forks 100 -i $inventory"
opts_adhoc="$opts -e @conf/satperf.yaml -e @$local_conf"


section "Checking environment"
generic_environment_check


export skip_measurement='true'

section "Upload manifest"
h_out "--no-headers --csv organization list --fields name" | grep -q "^$organization$" \
  || h 10-ensure-org.log "organization create --name '$organization'"
h 10-ensure-loc-in-org.log "organization add-location --name '$organization' --location '$dl'"
a 10-manifest-deploy.log -m copy -a "src=$manifest dest=/root/manifest-auto.zip force=yes" satellite6
h 10-manifest-upload.log "subscription upload --file '/root/manifest-auto.zip' --organization '$organization'"
s $wait_interval


section "Sync from CDN"   # do not measure because of unpredictable network latency
h 20-set-cdn-stage.log "organization update --name '$organization' --redhat-repository-url '$cdn_url_full'"

h 20-manifest-refresh.log "subscription refresh-manifest --organization '$organization'"

# RHEL 8
h 20-reposet-enable-rhel8baseos.log  "repository-set enable --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - BaseOS (RPMs)' --releasever '8' --basearch 'x86_64'"
h 20-repo-sync-rhel8baseos.log "repository synchronize --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - BaseOS RPMs 8'"
s $wait_interval
h 20-reposet-enable-rhel8appstream.log  "repository-set enable --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - AppStream (RPMs)' --releasever '8' --basearch 'x86_64'"
h 20-repo-sync-rhel8appstream.log "repository synchronize --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - AppStream RPMs 8'"
s $wait_interval


section "Sync Client repos"   # do not measure because of unpredictable network latency
h 24-sat-client-product-create.log "product create --organization '$organization' --name SatClientProduct"

# Satellite Client for RHEL 8
h 24-repository-create-sat-client_8.log "repository create --organization '$organization' --product SatClientProduct --name SatClient8Repo --content-type yum --url '$repo_sat_client_8'"
h 24-repository-sync-sat-client_8.log "repository synchronize --organization '$organization' --product SatClientProduct --name SatClient8Repo"
s $wait_interval


section "Create, publish and promote CV / LCE"
lce='LCE_Perf'
# RHEL 8
cv='CV_RHEL8'
rids="$( get_repo_id 'Red Hat Enterprise Linux for x86_64' 'Red Hat Enterprise Linux 8 for x86_64 - BaseOS RPMs 8' )"
rids="$rids,$( get_repo_id 'Red Hat Enterprise Linux for x86_64' 'Red Hat Enterprise Linux 8 for x86_64 - AppStream RPMs 8' )"
rids="$rids,$( get_repo_id 'SatClientProduct' 'SatClient8Repo' )"

h 25-rhel8-cv-create.log "content-view create --organization '$organization' --repository-ids '$rids' --name '$cv'"
h 25-rhel8-cv-publish.log "content-view publish --organization '$organization' --name '$cv'"

h 26-rhel8-lce-create.log "lifecycle-environment create --organization '$organization' --prior 'Library' --name '$lce'"
tmp=$( mktemp )
h_out "--no-headers --csv content-view version list --organization '$organization' --content-view '$cv' --lifecycle-environment 'Library' --fields version" >$tmp
cat $tmp
latest_version=$( tail -1 $tmp  )
rm -f $tmp
h 27-rhel8-lce-promote.log "content-view version promote --organization '$organization' --content-view '$cv' --version '$latest_version' --to-lifecycle-environment '$lce'"
s $wait_interval


section "Push content to capsules"
ap 35-capsync-populate.log \
  -e "organization='$organization'" \
  -e "lces='$lce'" \
  playbooks/satellite/capsules-populate.yaml
s $wait_interval


section "Prepare for registrations"
tmp=$( mktemp )

h_out "--no-headers --csv domain list --search 'name = {{ domain }}'" | grep -q '^[0-9]\+,' \
  || h 42-domain-create.log "domain create --name '{{ domain }}' --organizations '$organization'"

h_out "--no-headers --csv location list --organization '$organization'" | grep '^[0-9]\+,' >$tmp
location_ids=$( cut -d ',' -f 1 $tmp | tr '\n' ',' | sed 's/,$//' )
rm -f $tmp
h 42-domain-update.log "domain update --name '{{ domain }}' --organizations '$organization' --location-ids '$location_ids'"

ak='AK_RHEL8'
h 43-ak-create.log "activation-key create --content-view '$cv' --lifecycle-environment '$lce' --name '$ak' --organization '$organization'"

h_out "--csv subscription list --organization '$organization' --search 'name = \"$rhel_subscription\"'" >$logs/43-subs-list-rhel.log
rhel_subs_id=$( tail -n 1 $logs/43-subs-list-rhel.log | cut -d ',' -f 1 )
h 43-ak-add-subs-rhel.log "activation-key add-subscription --organization '$organization' --name '$ak' --subscription-id '$rhel_subs_id'"

h_out "--csv subscription list --organization '$organization' --search 'name = SatClientProduct'" >$logs/43-subs-list-sat-client.log
client_subs_id=$( tail -n 1 $logs/43-subs-list-sat-client.log | cut -d ',' -f 1 )
h 43-ak-add-subs-sat-client.log "activation-key add-subscription --organization '$organization' --name '$ak' --subscription-id '$client_subs_id'"

tmp=$( mktemp )
h_out "--no-headers --csv capsule list --organization '$organization'" | grep '^[0-9]\+,' >$tmp
for row in $( cut -d ' ' -f 1 $tmp ); do
    capsule_id=$( echo "$row" | cut -d ',' -f 1 )
    capsule_name=$( echo "$row" | cut -d ',' -f 2 )
    subnet_name="subnet-for-$capsule_name"
    hostgroup_name="hostgroup-for-$capsule_name"
    if [ "$capsule_id" -eq 1 ]; then
        location_name="$dl"
    else
        location_name="Location for $capsule_name"
    fi

    h_out "--no-headers --csv subnet list --search 'name = $subnet_name'" | grep -q '^[0-9]\+,' \
      || h 44-subnet-create-$capsule_name.log "subnet create --name '$subnet_name' --ipam None --domains '{{ domain }}' --organization '$organization' --network 172.0.0.0 --mask 255.0.0.0 --location '$location_name'"
    
    subnet_id=$( h_out "--output yaml subnet info --name '$subnet_name'" | grep '^Id:' | cut -d ' ' -f 2 )
    a 45-subnet-add-rex-capsule-$capsule_name.log \
      -m "ansible.builtin.uri" \
      -a "url=https://{{ groups['satellite6'] | first }}/api/v2/subnets/${subnet_id} force_basic_auth=true user={{ sat_user }} password={{ sat_pass }} method=PUT body_format=json body='{\"subnet\": {\"remote_execution_proxy_ids\": [\"${capsule_id}\"]}}'" \
      satellite6

    h_out "--no-headers --csv hostgroup list --search 'name = $hostgroup_name'" | grep -q '^[0-9]\+,' \
      || ap 46-hostgroup-create-$capsule_name.log \
           -e "organization='$organization'" \
           -e "hostgroup_name='$hostgroup_name'" \
           -e "subnet_name='$subnet_name'" \
           playbooks/satellite/hostgroup-create.yaml
done
rm -f $tmp

ap 49-generate-host-registration-command.log \
  -e "ak='$ak'" \
  playbooks/satellite/host-registration_generate-command.yaml

ap 49-recreate-client-scripts.log \
  playbooks/satellite/client-scripts.yaml

unset skip_measurement


section "Incremental registrations"
number_container_hosts=$( ansible -i $inventory --list-hosts container_hosts 2>/dev/null | grep '^  hosts' | sed 's/^  hosts (\([0-9]\+\)):$/\1/' )
number_containers_per_container_host=$( ansible -i $inventory -m debug -a "var=containers_count" container_hosts[0] | awk '/    "containers_count":/ {print $NF}' )
if (( initial_expected_concurrent_registrations > number_container_hosts )); then
    initial_concurrent_registrations_per_container_host="$(( initial_expected_concurrent_registrations / number_container_hosts ))"
else
    initial_concurrent_registrations_per_container_host=1
fi

for (( batch=1, remaining_containers_per_container_host=$number_containers_per_container_host; remaining_containers_per_container_host > 0; batch++ )); do
    if (( remaining_containers_per_container_host > initial_concurrent_registrations_per_container_host * batch )); then
        concurrent_registrations_per_container_host="$(( initial_concurrent_registrations_per_container_host * batch ))"
    else
        concurrent_registrations_per_container_host="$(( remaining_containers_per_container_host ))"
    fi
    concurrent_registrations="$(( concurrent_registrations_per_container_host * number_container_hosts ))"
    (( remaining_containers_per_container_host -= concurrent_registrations_per_container_host ))

    log "Trying to register $concurrent_registrations content hosts concurrently in this batch"

    skip_measurement='true' ap 50-register-$concurrent_registrations.log \
      -e "size=$concurrent_registrations_per_container_host" \
      -e "registration_logs='../../$logs/50-register-docker-host-client-logs'" \
      -e "debug_rhsm=true" \
      playbooks/tests/registrations.yaml
      e Register $logs/50-register-$concurrent_registrations.log
    s $wait_interval
done
grep Register $logs/50-register-*.log >$logs/50-register-overall.log
e Register $logs/50-register-overall.log


section "Sosreport"
skip_measurement='true' ap sosreporter-gatherer.log playbooks/satellite/sosreport_gatherer.yaml -e "sosreport_gatherer_local_dir='../../$logs/sosreport/'"

junit_upload
