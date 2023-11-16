#!/bin/bash

source experiment/run-library.sh

organization="${PARAM_organization:-Default Organization}"
manifest="${PARAM_manifest:-conf/contperf/manifest_SCA.zip}"
inventory="${PARAM_inventory:-conf/contperf/inventory.ini}"
local_conf="${PARAM_local_conf:-conf/satperf.local.yaml}"

expected_concurrent_registrations=${PARAM_expected_concurrent_registrations:-64}
initial_batch=${PARAM_initial_batch:-1}

cdn_url_full="${PARAM_cdn_url_full:-https://cdn.redhat.com/}"

repo_sat_client_8="${PARAM_repo_sat_client_8:-http://mirror.example.com/Satellite_Client_8_x86_64/}"

rhel_subscription="${PARAM_rhel_subscription:-Red Hat Enterprise Linux Server, Standard (Physical or Virtual Nodes)}"

dl="Default Location"

opts="--forks 100 -i $inventory"
opts_adhoc="$opts -e @conf/satperf.yaml -e @$local_conf"


section "Checking environment"
generic_environment_check


section "Prepare for Red Hat content"
h_out "--no-headers --csv organization list --fields name" | grep --quiet "^$organization$" \
  || h 00-ensure-org.log "organization create --name '$organization'"
skip_measurement='true' h 00-ensure-loc-in-org.log "organization add-location --name '$organization' --location '$dl'"
skip_measurement='true' ap 01-manifest-excercise.log \
  -e "manifest='../../$manifest'" \
  playbooks/tests/manifest-excercise.yaml
e ManifestUpload $logs/01-manifest-excercise.log
e ManifestRefresh $logs/01-manifest-excercise.log
e ManifestDelete $logs/01-manifest-excercise.log
skip_measurement='true' h 02-manifest-upload.log "subscription upload --file '/root/manifest-auto.zip' --organization '$organization'"


export skip_measurement='true'
section "Sync from CDN"   # do not measure becasue of unpredictable network latency
h 00b-set-cdn-stage.log "organization update --name '$organization' --redhat-repository-url '$cdn_url_full'"

h 00b-manifest-refresh.log "subscription refresh-manifest --organization '$organization'"

# RHEL 8
h 12b-reposet-enable-rhel8baseos.log "repository-set enable --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - BaseOS (RPMs)' --releasever '8' --basearch 'x86_64'"
h 12b-repo-sync-rhel8baseos.log "repository synchronize --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - BaseOS RPMs 8'"

h 12b-reposet-enable-rhel8appstream.log "repository-set enable --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - AppStream (RPMs)' --releasever '8' --basearch 'x86_64'"
h 12b-repo-sync-rhel8appstream.log "repository synchronize --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - AppStream RPMs 8'"
unset skip_measurement


export skip_measurement='true'
section "Sync Satellite Client repos"
h 15-sat-client-product-create.log "product create --organization '$organization' --name SatClientProduct"

# Satellite Client for RHEL 8
h 15-repository-create-sat-client_8.log "repository create --organization '$organization' --product SatClientProduct --name SatClient8Repo --content-type yum --url '$repo_sat_client_8'"
h 15-repository-sync-sat-client_8.log "repository synchronize --organization '$organization' --product SatClientProduct --name SatClient8Repo"
unset skip_measurement


section "Create, publish and promote CV / LCE"
# RHEL 8
rids="$( get_repo_id 'Red Hat Enterprise Linux for x86_64' 'Red Hat Enterprise Linux 8 for x86_64 - BaseOS RPMs 8' )"
rids="$rids,$( get_repo_id 'Red Hat Enterprise Linux for x86_64' 'Red Hat Enterprise Linux 8 for x86_64 - AppStream RPMs 8' )"
rids="$rids,$( get_repo_id 'SatClientProduct' 'SatClient8Repo' )"
cv='CV_RHEL8'
lce='LCE_RHEL8'

skip_measurement='true' h 25-rhel8-cv-create.log "content-view create --organization '$organization' --repository-ids '$rids' --name '$cv'"
h 25-rhel8-cv-publish.log "content-view publish --organization '$organization' --name '$cv'"

skip_measurement='true' h 26-rhel8-lce-create.log "lifecycle-environment create --organization '$organization' --prior 'Library' --name '$lce'"
h 27-rhel8-lce-promote.log "content-view version promote --organization '$organization' --content-view '$cv' --to-lifecycle-environment 'Library' --to-lifecycle-environment '$lce'"


export skip_measurement='true'
section "Push content to capsules"
ap 35-capsync-populate.log \
  -e "organization='$organization'" \
  -e "lces='$lce'" \
  playbooks/satellite/capsules-populate.yaml
unset skip_measurement


export skip_measurement='true'
section "Prepare for registrations"
tmp=$( mktemp )

h_out "--no-headers --csv domain list --search 'name = {{ domain }}'" | grep --quiet '^[0-9]\+,' \
  || h 42-domain-create.log "domain create --name '{{ domain }}' --organizations '$organization'"

h_out "--no-headers --csv location list --organization '$organization'" | grep '^[0-9]\+,' >$tmp
location_ids=$( cut -d ',' -f 1 $tmp | tr '\n' ',' | sed 's/,$//' )
h 42-domain-update.log "domain update --name '{{ domain }}' --organizations '$organization' --location-ids '$location_ids'"

ak='AK_RHEL8'
h 43-ak-create.log "activation-key create --content-view '$cv' --lifecycle-environment '$lce' --name '$ak' --organization '$organization'"

h_out "--csv subscription list --organization '$organization' --search 'name = \"$rhel_subscription\"'" >$logs/subs-list-rhel.log
rhel_subs_id=$( tail -n 1 $logs/subs-list-rhel.log | cut -d ',' -f 1 )
h 43-ak-add-subs-rhel.log "activation-key add-subscription --organization '$organization' --name '$ak' --subscription-id '$rhel_subs_id'"

h_out "--csv subscription list --organization '$organization' --search 'name = SatClientProduct'" >$logs/subs-list-client.log
client_subs_id=$( tail -n 1 $logs/subs-list-client.log | cut -d ',' -f 1 )
h 43-ak-add-subs-client.log "activation-key add-subscription --organization '$organization' --name '$ak' --subscription-id '$client_subs_id'"

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

    h_out "--no-headers --csv subnet list --search 'name = $subnet_name'" | grep --quiet '^[0-9]\+,' \
      || h 44-subnet-create-$capsule_name.log "subnet create --name '$subnet_name' --ipam None --domains '{{ domain }}' --organization '$organization' --network 172.0.0.0 --mask 255.0.0.0 --location '$location_name'"
    
    subnet_id=$( h_out "--output yaml subnet info --name '$subnet_name'" | grep '^Id:' | cut -d ' ' -f 2 )
    a 45-subnet-add-rex-capsule-$capsule_name.log \
      -m "ansible.builtin.uri" \
      -a "url=https://{{ groups['satellite6'] | first }}/api/v2/subnets/${subnet_id} force_basic_auth=true user={{ sat_user }} password={{ sat_pass }} method=PUT body_format=json body='{\"subnet\": {\"remote_execution_proxy_ids\": [\"${capsule_id}\"]}}'" \
      satellite6

    h_out "--no-headers --csv hostgroup list --search 'name = $hostgroup_name'" | grep --quiet '^[0-9]\+,' \
      || ap 41-hostgroup-create-$capsule_name.log \
           -e "organization='$organization'" \
           -e "hostgroup_name='$hostgroup_name'" \
           -e "subnet_name='$subnet_name'" \
           playbooks/satellite/hostgroup-create.yaml
done

ap 44-generate-host-registration-command.log \
  -e "ak='$ak'" \
  playbooks/satellite/host-registration_generate-command.yaml

ap 44-recreate-client-scripts.log \
  playbooks/satellite/client-scripts.yaml
unset skip_measurement


section "Register"
number_container_hosts=$( ansible -i $inventory --list-hosts container_hosts 2>/dev/null | grep '^  hosts' | sed 's/^  hosts (\([0-9]\+\)):$/\1/' )
number_containers_per_container_host=$( ansible -i $inventory -m debug -a "var=containers_count" container_hosts[0] | awk '/    "containers_count":/ {print $NF}' )
total_number_containers=$(( number_container_hosts * number_containers_per_container_host ))
concurrent_registrations_per_container_host=$(( expected_concurrent_registrations / number_container_hosts ))
real_concurrent_registrations=$(( concurrent_registrations_per_container_host * number_container_hosts ))
registration_iterations=$(( ( total_number_containers + real_concurrent_registrations - 1 ) / real_concurrent_registrations )) # We want ceiling rounding: Ceiling( X / Y ) = ( X + Y – 1 ) / Y

log "Going to register $total_number_containers hosts: $concurrent_registrations_per_container_host hosts per container host ($number_container_hosts available) in $(( registration_iterations + 1 )) batches."

for (( i=initial_batch; i <= ( registration_iterations + 1 ); i++ )); do
    skip_measurement='true' ap 44b-register-$i.log \
      -e "size='${concurrent_registrations_per_container_host}'" \
      -e "registration_logs='../../$logs/44b-register-container-host-client-logs'" \
      -e 're_register_failed_hosts=true' \
      playbooks/tests/registrations.yaml
    e Register $logs/44b-register-$i.log
done
grep Register $logs/44b-register-*.log >$logs/44b-register-overall.log
e Register $logs/44b-register-overall.log


section "Sosreport"
ap sosreporter-gatherer.log \
  -e "sosreport_gatherer_local_dir='../../$logs/sosreport/'" \
  playbooks/satellite/sosreport_gatherer.yaml


junit_upload
