#!/bin/bash

source experiment/run-library.sh

organization="${PARAM_organization:-Default Organization}"
manifest="${PARAM_manifest:-conf/contperf/manifest_SCA.zip}"
inventory="${PARAM_inventory:-conf/contperf/inventory.ini}"
local_conf="${PARAM_local_conf:-conf/satperf.local.yaml}"

concurrent_registrations=${PARAM_concurrent_registrations:-125}

wait_interval=${PARAM_wait_interval:-30}

cdn_url_full="${PARAM_cdn_url_full:-https://cdn.redhat.com/}"

repo_sat_tools="${PARAM_repo_sat_tools:-http://mirror.example.com/Satellite_Tools_x86_64/}"
# repo_sat_tools_puppet="${PARAM_repo_sat_tools_puppet:-none}"   # Older example: http://mirror.example.com/Satellite_Tools_Puppet_4_6_3_RHEL7_x86_64/

# repo_sat_client_7="${PARAM_repo_sat_client_7:-http://mirror.example.com/Satellite_Client_7_x86_64/}"
repo_sat_client_8="${PARAM_repo_sat_client_8:-http://mirror.example.com/Satellite_Client_8_x86_64/}"
# repo_sat_client_9="${PARAM_repo_sat_client_9:-http://mirror.example.com/Satellite_Client_9_x86_64/}"

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
  -e "manifest=../../$manifest" \
  playbooks/tests/manifest-excercise.yaml
e ManifestUpload $logs/01-manifest-excercise.log
e ManifestRefresh $logs/01-manifest-excercise.log
e ManifestDelete $logs/01-manifest-excercise.log
skip_measurement='true' h 02-manifest-upload.log "subscription upload --file '/root/manifest-auto.zip' --organization '$organization'"
s $wait_interval


export skip_measurement='true'
section "Sync from CDN"   # do not measure becasue of unpredictable network latency
h 00b-set-cdn-stage.log "organization update --name '$organization' --redhat-repository-url '$cdn_url_full'"

h 00b-manifest-refresh.log "subscription refresh-manifest --organization '$organization'"

# h 12b-reposet-enable-rhel7.log "repository-set enable --organization '$organization' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server (RPMs)' --releasever '7Server' --basearch 'x86_64'"
# h 12b-repo-sync-rhel7.log "repository synchronize --organization '$organization' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server'"
# s $wait_interval
# h 12b-repo-sync-rhel7optional.log "repository synchronize --organization '$organization' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server - Optional RPMs x86_64 7Server'"
# s $wait_interval

h 12b-reposet-enable-rhel8baseos.log "repository-set enable --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - BaseOS (RPMs)' --releasever '8' --basearch 'x86_64'"
h 12b-repo-sync-rhel8baseos.log "repository synchronize --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - BaseOS RPMs 8'"
s $wait_interval
h 12b-reposet-enable-rhel8appstream.log "repository-set enable --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - AppStream (RPMs)' --releasever '8' --basearch 'x86_64'"
h 12b-repo-sync-rhel8appstream.log "repository synchronize --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - AppStream RPMs 8'"
s $wait_interval

# h 12b-reposet-enable-rhel9baseos.log "repository-set enable --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 9 for x86_64 - BaseOS (RPMs)' --releasever '9' --basearch 'x86_64'"
# h 12b-repo-sync-rhel9baseos.log "repository synchronize --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 9 for x86_64 - BaseOS RPMs 9'"
# s $wait_interval
# h 12b-reposet-enable-rhel9appstream.log "repository-set enable --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 9 for x86_64 - AppStream (RPMs)' --releasever '9' --basearch 'x86_64'"
# h 12b-repo-sync-rhel9appstream.log "repository synchronize --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 9 for x86_64 - AppStream RPMs 9'"
# s $wait_interval
unset skip_measurement


export skip_measurement='true'
section "Sync Tools repo"
h product-create.log "product create --organization '$organization' --name SatToolsProduct"

h repository-create-sat-tools.log "repository create --organization '$organization' --product SatToolsProduct --name SatToolsRepo --content-type yum --url '$repo_sat_tools'"
h repository-sync-sat-tools.log "repository synchronize --organization '$organization' --product SatToolsProduct --name SatToolsRepo" &

# [ "$repo_sat_tools_puppet" != "none" ] \
#   && h repository-create-puppet-upgrade.log "repository create --organization '$organization' --product SatToolsProduct --name SatToolsPuppetRepo --content-type yum --url '$repo_sat_tools_puppet'"
# [ "$repo_sat_tools_puppet" != "none" ] \
#   && h repository-sync-puppet-upgrade.log "repository synchronize --organization '$organization' --product SatToolsProduct --name SatToolsPuppetRepo" &
wait
unset skip_measurement


export skip_measurement='true'
section "Sync Client repos"
h 30-sat-client-product-create.log "product create --organization '$organization' --name SatClientProduct"

# h 30-repository-create-sat-client_7.log "repository create --organization '$organization' --product SatClientProduct --name SatClient7Repo --content-type yum --url '$repo_sat_client_7'"
# h 30-repository-sync-sat-client_7.log "repository synchronize --organization '$organization' --product SatClientProduct --name SatClient7Repo" &

h 30-repository-create-sat-client_8.log "repository create --organization '$organization' --product SatClientProduct --name SatClient8Repo --content-type yum --url '$repo_sat_client_8'"
h 30-repository-sync-sat-client_8.log "repository synchronize --organization '$organization' --product SatClientProduct --name SatClient8Repo" &

# h 30-repository-create-sat-client_9.log "repository create --organization '$organization' --product SatClientProduct --name SatClient9Repo --content-type yum --url '$repo_sat_client_9'"
# h 30-repository-sync-sat-client_9.log "repository synchronize --organization '$organization' --product SatClientProduct --name SatClient9Repo" &
wait
unset skip_measurement


export skip_measurement='true'
section "Synchronise capsules"
tmp=$( mktemp )
h_out "--no-headers --csv capsule list --organization '$organization'" | grep '^[0-9]\+,' >$tmp
for capsule_id in $( cat $tmp | cut -d ',' -f 1 | grep -v '1' ); do
    h 13b-capsule-sync-$capsule_id.log "capsule content synchronize --organization '$organization' --id '$capsule_id'"
done
s $wait_interval
unset skip_measurement


export skip_measurement='true'
section "Prepare for registrations"
tmp=$( mktemp )

h_out "--no-headers --csv domain list --search 'name = {{ containers_domain }}'" | grep --quiet '^[0-9]\+,' \
  || h 42-domain-create.log "domain create --name '{{ containers_domain }}' --organizations '$organization'"

h_out "--no-headers --csv location list --organization '$organization'" | grep '^[0-9]\+,' >$tmp
location_ids=$( cut -d ',' -f 1 $tmp | tr '\n' ',' | sed 's/,$//' )
h 42-domain-update.log "domain update --name '{{ containers_domain }}' --organizations '$organization' --location-ids '$location_ids'"

h 43-ak-create.log "activation-key create --content-view '$organization View' --lifecycle-environment Library --name ActivationKey --organization '$organization'"

h_out "--csv subscription list --organization '$organization' --search 'name = \"$rhel_subscription\"'" >$logs/subs-list-rhel.log
rhel_subs_id=$( tail -n 1 $logs/subs-list-rhel.log | cut -d ',' -f 1 )
h 43-ak-add-subs-rhel.log "activation-key add-subscription --organization '$organization' --name ActivationKey --subscription-id '$rhel_subs_id'"

h_out "--csv subscription list --organization '$organization' --search 'name = SatToolsProduct'" >$logs/subs-list-tools.log
tools_subs_id=$( tail -n 1 $logs/subs-list-tools.log | cut -d ',' -f 1 )
h 43-ak-add-subs-tools.log "activation-key add-subscription --organization '$organization' --name ActivationKey --subscription-id '$tools_subs_id'"

h_out "--csv subscription list --organization '$organization' --search 'name = SatClientProduct'" >$logs/subs-list-client.log
client_subs_id=$( tail -n 1 $logs/subs-list-client.log | cut -d ',' -f 1 )
h 43-ak-add-subs-client.log "activation-key add-subscription --organization '$organization' --name ActivationKey --subscription-id '$client_subs_id'"

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
      || h 44-subnet-create-$capsule_name.log "subnet create --name '$subnet_name' --ipam None --domains '{{ containers_domain }}' --organization '$organization' --network 172.0.0.0 --mask 255.0.0.0 --location '$location_name'"
    
    subnet_id=$( h_out "--output yaml subnet info --name '$subnet_name'" | grep '^Id:' | cut -d ' ' -f 2 )
    a 45-subnet-add-rex-capsule-$capsule_name.log satellite6 \
      -m "shell" \
      -a "curl --silent --insecure -u {{ sat_user }}:{{ sat_pass }} -X PUT -H 'Accept: application/json' -H 'Content-Type: application/json' https://localhost/api/v2/subnets/$subnet_id -d '{\"subnet\": {\"remote_execution_proxy_ids\": [\"$capsule_id\"]}}'"
    h_out "--no-headers --csv hostgroup list --search 'name = $hostgroup_name'" | grep --quiet '^[0-9]\+,' \
      || ap 41-hostgroup-create-$capsule_name.log \
          -e "organization='$organization'" \
          -e "hostgroup_name=$hostgroup_name" \
          -e "subnet_name=$subnet_name" \
          playbooks/satellite/hostgroup-create.yaml
done

ap 44-generate-host-registration-command.log \
  -e "ak=ActivationKey" \
  playbooks/satellite/host-registration_generate-command.yaml
ap 44-recreate-client-scripts.log \
  playbooks/satellite/client-scripts.yaml
unset skip_measurement


section "Register"
number_container_hosts=$( ansible -i $inventory --list-hosts container_hosts 2>/dev/null | grep '^  hosts' | sed 's/^  hosts (\([0-9]\+\)):$/\1/' )
number_containers_per_container_host=$( ansible -i $inventory -m debug -a "var=containers_count" container_hosts[0] | awk '/    "containers_count":/ {print $NF}' )
total_number_containers=$(( number_container_hosts * number_containers_per_container_host ))
registration_iterations=$(( ( total_number_containers + concurrent_registrations - 1 ) / concurrent_registrations )) # We want ceiling rounding: Ceiling( X / Y ) = ( X + Y – 1 ) / Y
concurrent_registrations_per_container_host=$(( concurrent_registrations / number_container_hosts ))

log "Going to register $total_number_containers hosts: $concurrent_registrations_per_container_host hosts per container host ($number_container_hosts available) in $(( registration_iterations + 1 )) batches."

for (( i=1; i <= ( registration_iterations + 1 ); i++ )); do
    skip_measurement='true' ap 44b-register-$i.log \
      -e "size=${concurrent_registrations_per_container_host}" \
      -e "registration_logs='../../$logs/44b-register-container-host-client-logs'" \
      -e "method=clients_host-registration" \
      playbooks/tests/registrations.yaml
    e Register $logs/44b-register-$i.log
    s $wait_interval
done
grep Register $logs/44b-register-*.log >$logs/44b-register-overall.log
e Register $logs/44b-register-overall.log


section "Sosreport"
ap sosreporter-gatherer.log \
  -e "sosreport_gatherer_local_dir='../../$logs/sosreport/'" \
  playbooks/satellite/sosreport_gatherer.yaml

junit_upload
