#!/bin/bash

source experiment/run-library.sh

organization="${PARAM_organization:-Default Organization}"
manifest="${PARAM_manifest:-conf/contperf/manifest_SCA.zip}"
inventory="${PARAM_inventory:-conf/contperf/inventory.ini}"
private_key="${PARAM_private_key:-conf/contperf/id_rsa_perf}"
local_conf="${PARAM_local_conf:-conf/satperf.local.yaml}"

registrations_per_docker_hosts=${PARAM_registrations_per_docker_hosts:-5}
registrations_iterations=${PARAM_registrations_iterations:-20}
wait_interval=${PARAM_wait_interval:-50}

repo_sat_client_7="${PARAM_repo_sat_client_7:-http://mirror.example.com/Satellite_Client_7_x86_64/}"
repo_sat_client_8="${PARAM_repo_sat_client_8:-http://mirror.example.com/Satellite_Client_8_x86_64/}"

rhel_subscription="${PARAM_rhel_subscription:-Red Hat Enterprise Linux Server, Standard (Physical or Virtual Nodes)}"

dl="Default Location"

opts="--forks 100 -i $inventory --private-key $private_key"
opts_adhoc="$opts -e @conf/satperf.yaml -e @$local_conf"


section "Util: Prepare for Red Hat content"
h_out "--no-headers --csv organization list --fields name" | grep --quiet "^$organization$" \
    || h regs-10-ensure-org.log "organization create --name '$organization'"
h 00-ensure-loc-in-org.log "organization add-location --name '$organization' --location '$dl'"
a 00-manifest-deploy.log -m copy -a "src=$manifest dest=/root/manifest-auto.zip force=yes" satellite6
h 01-manifest-upload.log "subscription upload --file '/root/manifest-auto.zip' --organization '$organization'"
h 03-manifest-refresh.log "subscription refresh-manifest --organization '$organization'"
s $wait_interval


section "Util: Sync Client repos"
h client-product-create.log "product create --organization '$organization' --name SatClientProduct"
h repository-create-sat-client_7.log "repository create --organization '$organization' --product SatClientProduct --name SatClient7Repo --content-type yum --url '$repo_sat_client_7'"
h repository-sync-sat-client_7.log "repository synchronize --organization '$organization' --product SatClientProduct --name SatClient7Repo"
s $wait_interval
h repository-create-sat-client_8.log "repository create --organization '$organization' --product SatClientProduct --name SatClient8Repo --content-type yum --url '$repo_sat_client_8'"
h repository-sync-sat-client_8.log "repository synchronize --organization '$organization' --product SatClientProduct --name SatClient8Repo"
s $wait_interval


h regs-40-ak-create.log "activation-key create --content-view '$organization View' --lifecycle-environment Library --name ActivationKey --organization '$organization'"
h_out "--csv subscription list --organization '$organization' --search 'name = \"$rhel_subscription\"'" >$logs/subs-list-rhel.log
rhel_subs_id=$( tail -n 1 $logs/subs-list-rhel.log | cut -d ',' -f 1 )
skip_measurement='true' h 43-ak-add-subs-rhel.log "activation-key add-subscription --organization '$organization' --name ActivationKey --subscription-id '$rhel_subs_id'"
h_out "--csv subscription list --organization '$organization' --search 'name = SatClientProduct'" >$logs/subs-list-client.log
client_subs_id=$( tail -n 1 $logs/subs-list-client.log | cut -d ',' -f 1 )
skip_measurement='true' h 43-ak-add-subs-client.log "activation-key add-subscription --organization '$organization' --name ActivationKey --subscription-id '$client_subs_id'"

section "Util: Prepare for registrations"
ap 40-recreate-client-scripts.log playbooks/satellite/client-scripts.yaml   # this detects OS, so need to run after we synces one
h_out "--no-headers --csv domain list --search 'name = {{ domain }}'" | grep --quiet '^[0-9]\+,' \
    || h 42-domain-create.log "domain create --name '{{ domain }}' --organizations '$organization'"
tmp=$( mktemp )
h_out "--no-headers --csv location list --organization '$organization'" | grep '^[0-9]\+,' >$tmp
location_ids=$( cut -d ',' -f 1 $tmp | tr '\n' ',' | sed 's/,$//' )
h 42-domain-update.log "domain update --name '{{ domain }}' --organizations '$organization' --location-ids '$location_ids'"
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
    a 45-subnet-add-rex-capsule-$capsule_name.log satellite6 -m "shell" -a "curl --silent --insecure -u {{ sat_user }}:{{ sat_pass }} -X PUT -H 'Accept: application/json' -H 'Content-Type: application/json' https://localhost//api/v2/subnets/$subnet_id -d '{\"subnet\": {\"remote_execution_proxy_ids\": [\"$capsule_id\"]}}'"
    h_out "--no-headers --csv hostgroup list --search 'name = $hostgroup_name'" | grep --quiet '^[0-9]\+,' \
        || ap regs-41-hostgroup-create-$capsule_name.log playbooks/satellite/hostgroup-create.yaml -e "organization='$organization' hostgroup_name=$hostgroup_name subnet_name=$subnet_name"
done

skip_measurement='true' ap 44-recreate-client-scripts.log playbooks/satellite/client-scripts.yaml -e "registration_hostgroup=hostgroup-for-{{ tests_registration_target }}"

section "Util: Register"
for i in $( seq $registrations_iterations ); do
    ap 44-register-$i.log playbooks/tests/registrations.yaml -e "size=$registrations_per_docker_hosts tags=untagged,REG,REM bootstrap_activationkey='ActivationKey' bootstrap_hostgroup='hostgroup-for-{{ tests_registration_target }}' grepper='Register' registration_logs='../../$logs/44-register-docker-host-client-logs'"
    e Register $logs/44-register-$i.log
    s $wait_interval
done




junit_upload
