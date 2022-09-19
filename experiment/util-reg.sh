#!/bin/bash

source experiment/run-library.sh

manifest="${PARAM_manifest:-conf/contperf/manifest.zip}"
inventory="${PARAM_inventory:-conf/contperf/inventory.ini}"
private_key="${PARAM_private_key:-conf/contperf/id_rsa_perf}"

registrations_per_container_hosts=${PARAM_registrations_per_container_hosts:-5}
registrations_iterations=${PARAM_registrations_iterations:-20}
wait_interval=${PARAM_wait_interval:-50}
all_rex=${PARAM_all_rex:-false}
skip_util_reg_setup=${PARAM_skip_util_reg_setup:-false}

repo_sat_tools="${PARAM_repo_sat_tools:-http://mirror.example.com/Satellite_Tools_x86_64/}"

repo_sat_client_7="${PARAM_repo_sat_client_7:-http://mirror.example.com/Satellite_Client_7_x86_64/}"
repo_sat_client_8="${PARAM_repo_sat_client_8:-http://mirror.example.com/Satellite_Client_8_x86_64/}"

do="Default Organization"
dl="Default Location"

opts="--forks 100 -i $inventory --private-key $private_key"
opts_adhoc="$opts --user root -e @conf/satperf.yaml -e @conf/satperf.local.yaml"

if [ "$skip_util_reg_setup" != "true" ]; then
    section "Util: Checking environment"
    generic_environment_check

    section "Util: Prepare for Red Hat content"
    h 00-ensure-loc-in-org.log "organization add-location --name 'Default Organization' --location 'Default Location'"
    a 00-manifest-deploy.log -m copy -a "src=$manifest dest=/root/manifest-auto.zip force=yes" satellite6
    h 01-manifest-upload.log "subscription upload --file '/root/manifest-auto.zip' --organization '$do'"
    h 03-manifest-refresh.log "subscription refresh-manifest --organization '$do'"
    skip_measurement='true' h 03-simple-content-access-disable.log "simple-content-access disable --organization '$do'"
    s $wait_interval

    section "Util: Sync Tools repo"
    h product-create.log "product create --organization '$do' --name SatToolsProduct"
    h repository-create-sat-tools.log "repository create --organization '$do' --product SatToolsProduct --name SatToolsRepo --content-type yum --url '$repo_sat_tools'"
    h repository-sync-sat-tools.log "repository synchronize --organization '$do' --product SatToolsProduct --name SatToolsRepo"
    s $wait_interval

    section "Util: Sync Client repos"
    h regs-30-sat-client-product-create.log "product create --organization '$do' --name SatClientProduct"
    h regs-30-repository-create-sat-client_7.log "repository create --organization '$do' --product SatClientProduct --name SatClient7Repo --content-type yum --url '$repo_sat_client_7'"
    h regs-30-repository-sync-sat-client_7.log "repository synchronize --organization '$do' --product SatClientProduct --name SatClient7Repo"
    s $wait_interval
    h regs-30-repository-create-sat-client_8.log "repository create --organization '$do' --product SatClientProduct --name SatClient8Repo --content-type yum --url '$repo_sat_client_8'"
    h regs-30-repository-sync-sat-client_8.log "repository synchronize --organization '$do' --product SatClientProduct --name SatClient8Repo"
    s $wait_interval
fi


section "Util: Prepare for registrations"
ap 40-recreate-client-scripts.log playbooks/satellite/client-scripts.yaml  # this detects OS, so need to run after we synces one
h_out "--no-headers --csv domain list --search 'name = {{ containers_domain }}'" | grep --quiet '^[0-9]\+,' \
    || h 42-domain-create.log "domain create --name '{{ containers_domain }}' --organizations '$do'"
tmp=$( mktemp )
h_out "--no-headers --csv location list --organization '$do'" | grep '^[0-9]\+,' >$tmp
location_ids=$( cut -d ',' -f 1 $tmp | tr '\n' ',' | sed 's/,$//' )
h 42-domain-update.log "domain update --name '{{ containers_domain }}' --organizations '$do' --location-ids '$location_ids'"

h regs-40-ak-create.log "activation-key create --content-view '$do View' --lifecycle-environment Library --name ActivationKey --organization '$do'"
h_out "--csv subscription list --organization '$do' --search 'name = SatToolsProduct'" >$logs/subs-list-tools.log
tools_subs_id=$( tail -n 1 $logs/subs-list-tools.log | cut -d ',' -f 1 )
skip_measurement='true' h 43-ak-add-subs-tools.log "activation-key add-subscription --organization '$do' --name ActivationKey --subscription-id '$tools_subs_id'"
h_out "--csv subscription list --organization '$do' --search 'name = \"Red Hat Enterprise Linux Server, Standard (Physical or Virtual Nodes)\"'" >$logs/subs-list-rhel.log
rhel_subs_id=$( tail -n 1 $logs/subs-list-rhel.log | cut -d ',' -f 1 )
skip_measurement='true' h 43-ak-add-subs-rhel.log "activation-key add-subscription --organization '$do' --name ActivationKey --subscription-id '$rhel_subs_id'"
h_out "--csv subscription list --organization '$do' --search 'name = SatClientProduct'" >$logs/subs-list-client.log
client_subs_id=$( tail -n 1 $logs/subs-list-client.log | cut -d ',' -f 1 )
skip_measurement='true' h 43-ak-add-subs-client.log "activation-key add-subscription --organization '$do' --name ActivationKey --subscription-id '$client_subs_id'"

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
        || h 44-subnet-create-$capsule_name.log "subnet create --name '$subnet_name' --ipam None --domains '{{ containers_domain }}' --organization '$do' --network 172.0.0.0 --mask 255.0.0.0 --location '$location_name'"
    subnet_id=$( h_out "--output yaml subnet info --name '$subnet_name'" | grep '^Id:' | cut -d ' ' -f 2 )
    a 45-subnet-add-rex-capsule-$capsule_name.log satellite6 -m "shell" -a "curl --silent --insecure -u {{ sat_user }}:{{ sat_pass }} -X PUT -H 'Accept: application/json' -H 'Content-Type: application/json' https://localhost//api/v2/subnets/$subnet_id -d '{\"subnet\": {\"remote_execution_proxy_ids\": [\"$capsule_id\"]}}'"
    h_out "--no-headers --csv hostgroup list --search 'name = $hostgroup_name'" | grep --quiet '^[0-9]\+,' \
        || ap regs-41-hostgroup-create-$capsule_name.log playbooks/satellite/hostgroup-create.yaml -e "Default_Organization='$do' hostgroup_name=$hostgroup_name subnet_name=$subnet_name"
done

skip_measurement='true' ap 44-recreate-client-scripts.log playbooks/satellite/client-scripts.yaml -e "registration_hostgroup=hostgroup-for-{{ tests_registration_target }}"

section "Util: Register"
for i in $( seq $registrations_iterations ); do
    ap 44-register-$i.log playbooks/tests/registrations.yaml -e "size=$registrations_per_container_hosts registration_logs='../../$logs/44-register-container-host-client-logs'"
    e Register $logs/44-register-$i.log
    s $wait_interval
done


section "Util: Remote execution"
h 50-rex-set-via-ip.log "settings set --name remote_execution_connect_by_ip --value true"
a 51-rex-cleanup-know_hosts.log satellite6 -m "shell" -a "rm -rf /usr/share/foreman-proxy/.ssh/known_hosts*"

if [ "$all_rex" != "false" ]; then
    h 52-rex-ssh-date.log "job-invocation create --inputs \"command='date'\" --job-template 'Run Command - SSH Default' --search-query 'name ~ container'"
    s $wait_interval
    h 52-rex-ssh-sm-facts-update.log "job-invocation create --inputs \"command='subscription-manager facts --update'\" --job-template 'Run Command - SSH Default' --search-query 'name ~ container'"
    s $wait_interval
    h 52-rex-ssh-uploadprofile.log "job-invocation create --inputs \"command='dnf uploadprofile --force-upload'\" --job-template 'Run Command - SSH Default' --search-query 'name ~ container'"
    s $wait_interval
    h 52-rex-ansible-date.log "job-invocation create --inputs \"command='date'\" --job-template 'Run Command - Ansible Default' --search-query 'name ~ container'"
    s $wait_interval
fi

junit_upload
