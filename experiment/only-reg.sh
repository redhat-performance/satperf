#!/bin/bash

source experiment/run-library.sh

manifest="${PARAM_manifest:-conf/contperf/manifest.zip}"
inventory="${PARAM_inventory:-conf/contperf/inventory.ini}"
private_key="${PARAM_private_key:-conf/contperf/id_rsa_perf}"

registrations_per_docker_hosts=${PARAM_registrations_per_docker_hosts:-5}
registrations_iterations=${PARAM_registrations_iterations:-20}
wait_interval=${PARAM_wait_interval:-50}

repo_sat_tools="${PARAM_repo_sat_tools:-http://mirror.example.com/Satellite_Tools_x86_64/}"

do="Default Organization"
dl="Default Location"

opts="--forks 100 -i $inventory --private-key $private_key"
opts_adhoc="$opts --user root -e @conf/satperf.yaml -e @conf/satperf.local.yaml"


section "Util: Prepare for Red Hat content"
h 00-ensure-loc-in-org.log "organization add-location --name 'Default Organization' --location 'Default Location'"
a 00-manifest-deploy.log -m copy -a "src=$manifest dest=/root/manifest-auto.zip force=yes" satellite6
h 01-manifest-upload.log "subscription upload --file '/root/manifest-auto.zip' --organization '$do'"
h 03-manifest-refresh.log "subscription refresh-manifest --organization '$do'"
s $wait_interval


section "Util: Sync Tools repo"
h product-create.log "product create --organization '$do' --name SatToolsProduct"
h repository-create-sat-tools.log "repository create --organization '$do' --product SatToolsProduct --name SatToolsRepo --content-type yum --url '$repo_sat_tools'"
h repository-sync-sat-tools.log "repository synchronize --organization '$do' --product SatToolsProduct --name SatToolsRepo"
s $wait_interval


section "Util: Prepare for registrations"
ap 40-recreate-client-scripts.log playbooks/satellite/client-scripts.yaml   # this detects OS, so need to run after we synces one
h_out "--no-headers --csv domain list --search 'name = {{ client_domain }}'" | grep --quiet '^[0-9]\+,' \
    || h 42-domain-create.log "domain create --name '{{ client_domain }}' --organizations '$do'"
tmp=$( mktemp )
h_out "--no-headers --csv location list --organization '$do'" | grep '^[0-9]\+,' >$tmp
location_ids=$( cut -d ',' -f 1 $tmp | tr '\n' ',' | sed 's/,$//' )
h 42-domain-update.log "domain update --name '{{ client_domain }}' --organizations '$do' --location-ids '$location_ids'"
tmp=$( mktemp )
h_out "--no-headers --csv capsule list --organization '$do'" | grep '^[0-9]\+,' >$tmp
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
        || h 44-subnet-create-$capsule_name.log "subnet create --name '$subnet_name' --ipam None --domains '{{ client_domain }}' --organization '$do' --network 172.0.0.0 --mask 255.0.0.0 --location '$location_name'"
    subnet_id=$( h_out "--output yaml subnet info --name '$subnet_name'" | grep '^Id:' | cut -d ' ' -f 2 )
    a 45-subnet-add-rex-capsule-$capsule_name.log satellite6 -m "shell" -a "curl --silent --insecure -u {{ sat_user }}:{{ sat_pass }} -X PUT -H 'Accept: application/json' -H 'Content-Type: application/json' https://localhost//api/v2/subnets/$subnet_id -d '{\"subnet\": {\"remote_execution_proxy_ids\": [\"$capsule_id\"]}}'"
    h_out "--no-headers --csv hostgroup list --search 'name = $hostgroup_name'" | grep --quiet '^[0-9]\+,' \
        || h 41-hostgroup-create-$capsule_name.log "hostgroup create --content-view 'Default Organization View' --lifecycle-environment Library --name '$hostgroup_name' --query-organization '$do' --subnet '$subnet_name'"
done
h 43-ak-create.log "activation-key create --content-view 'Default Organization View' --lifecycle-environment Library --name ActivationKey --organization '$do'"
h subs-list-tools.log "--csv subscription list --organization '$do' --search 'name = SatToolsProduct'"
tools_subs_id=$( tail -n 1 $logs/subs-list-tools.log | cut -d ',' -f 1 )
h ak-add-subs-tools.log "activation-key add-subscription --organization '$do' --name ActivationKey --subscription-id '$tools_subs_id'"
h subs-list-employee.log "--csv subscription list --organization '$do' --search 'name = \"Employee SKU\"'"
employee_subs_id=$( tail -n 1 $logs/subs-list-employee.log | cut -d ',' -f 1 )
h ak-add-subs-employee.log "activation-key add-subscription --organization '$do' --name ActivationKey --subscription-id '$employee_subs_id'"


section "Util: Register"
for i in $( seq $registrations_iterations ); do
    ap 44-register-$i.log playbooks/tests/registrations.yaml -e "size=$registrations_per_docker_hosts tags=untagged,REG,REM bootstrap_activationkey='ActivationKey' bootstrap_hostgroup='hostgroup-for-{{ tests_registration_target }}' grepper='Register' registration_logs='../../$logs/44-register-docker-host-client-logs'"
    e Register $logs/44-register-$i.log
    s $wait_interval
done




junit_upload
