#!/bin/bash

source experiment/run-library.sh

manifest="${PARAM_manifest:-conf/contperf/manifest.zip}"
inventory="${PARAM_inventory:-conf/contperf/inventory.ini}"
private_key="${PARAM_private_key:-conf/contperf/id_rsa_perf}"

wait_interval=${PARAM_wait_interval:-50}
registrations_batches="${PARAM_registrations_batches:-1 2 3}"
bootstrap_additional_args="${PARAM_bootstrap_additional_args}"   # usually you want this empty

cdn_url_full="${PARAM_cdn_url_full:-https://cdn.redhat.com/}"

repo_sat_tools="${PARAM_repo_sat_tools:-http://mirror.example.com/Satellite_Tools_x86_64/}"

do="Default Organization"
dl="Default Location"

opts="--forks 100 -i $inventory --private-key $private_key"
opts_adhoc="$opts --user root -e @conf/satperf.yaml -e @conf/satperf.local.yaml"


section "Checking environment"
generic_environment_check

export skip_measurement='true'


section "Prepare for registrations"
ap regs-40-recreate-client-scripts.log playbooks/satellite/client-scripts.yaml -e "registration_hostgroup=hostgroup-for-{{ tests_registration_target }}"  # this detects OS, so need to run after we synces one

h_out "--no-headers --csv domain list --search 'name = {{ containers_domain }}'" | grep --quiet '^[0-9]\+,' \
    || h regs-40-domain-create.log "domain create --name '{{ containers_domain }}' --organizations '$do'"
tmp=$( mktemp )
h_out "--no-headers --csv location list --organization '$do'" | grep '^[0-9]\+,' >$tmp
location_ids=$( cut -d ',' -f 1 $tmp | tr '\n' ',' | sed 's/,$//' )
h regs-40-domain-update.log "domain update --name '{{ containers_domain }}' --organizations '$do' --location-ids '$location_ids'"

h regs-40-ak-create.log "activation-key create --content-view '$do View' --lifecycle-environment Library --name ActivationKey --organization '$do'"
h_out "--csv subscription list --organization '$do' --search 'name = SatToolsProduct'" >$logs/subs-list-tools.log
tools_subs_id=$( tail -n 1 $logs/subs-list-tools.log | cut -d ',' -f 1 )
skip_measurement='true' h 43-ak-add-subs-tools.log "activation-key add-subscription --organization '$do' --name ActivationKey --subscription-id '$tools_subs_id'"
h_out "--csv subscription list --organization '$do' --search 'name = \"Red Hat Enterprise Linux Server, Standard (Physical or Virtual Nodes)\"'" >$logs/subs-list-rhel.log
rhel_subs_id=$( tail -n 1 $logs/subs-list-rhel.log | cut -d ',' -f 1 )
skip_measurement='true' h 43-ak-add-subs-rhel.log "activation-key add-subscription --organization '$do' --name ActivationKey --subscription-id '$rhel_subs_id'"

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
        || h regs-44-subnet-create-$capsule_name.log "subnet create --name '$subnet_name' --ipam None --domains '{{ containers_domain }}' --organization '$do' --network 172.0.0.0 --mask 255.0.0.0 --location '$location_name'"
    subnet_id=$( h_out "--output yaml subnet info --name '$subnet_name'" | grep '^Id:' | cut -d ' ' -f 2 )
    a regs-45-subnet-add-rex-capsule-$capsule_name.log satellite6 -m "shell" -a "curl --silent --insecure -u {{ sat_user }}:{{ sat_pass }} -X PUT -H 'Accept: application/json' -H 'Content-Type: application/json' https://localhost//api/v2/subnets/$subnet_id -d '{\"subnet\": {\"remote_execution_proxy_ids\": [\"$capsule_id\"]}}'"
    h_out "--no-headers --csv hostgroup list --search 'name = $hostgroup_name'" | grep --quiet '^[0-9]\+,' \
        || ap regs-41-hostgroup-create-$capsule_name.log playbooks/satellite/hostgroup-create.yaml -e "Default_Organization='$do' hostgroup_name=$hostgroup_name subnet_name=$subnet_name"
done

skip_measurement='true' ap 44-recreate-client-scripts.log playbooks/satellite/client-scripts.yaml -e "registration_hostgroup=hostgroup-for-{{ tests_registration_target }}"

section "Register more and more"
ansible_container_hosts=$( ansible -i $inventory --list-hosts container_hosts,container_hosts 2>/dev/null | grep '^  hosts' | sed 's/^  hosts (\([0-9]\+\)):$/\1/' )
sum=0
for b in $registrations_batches; do
    let sum+=$( expr $b \* $ansible_container_hosts )
done
log "Going to register $sum hosts in total. Make sure there is enough hosts available."

export skip_measurement='false'

iter=1
for batch in $registrations_batches; do
    ap regs-50-register-$iter-$batch.log playbooks/tests/registrations.yaml -e "size=$batch registration_logs='../../$logs/regs-50-register-container-host-client-logs'"
#     ap regs-50-register-$iter-$batch.log playbooks/tests/registrations.yaml -e "size=$batch tags=untagged,REG,REM bootstrap_activationkey='ActivationKey' bootstrap_hostgroup='hostgroup-for-{{ tests_registration_target }}' grepper='Register' registration_logs='../../$logs/regs-50-register-container-host-client-logs' method=clients-bootstrap.yaml registration_hostgroup=hostgroup-for-{{ tests_registration_target }}"
    e Register $logs/regs-50-register-$iter-$batch.log
    let iter+=1
    s $wait_interval
done

section "Summary"
iter=1
for batch in $registrations_batches; do
    log "$( experiment/reg-average.py Register $logs/regs-50-register-$iter-$batch.log | tail -n 1 )"
    let iter+=1
done

junit_upload
