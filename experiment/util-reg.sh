#!/bin/bash

source experiment/run-library.sh

branch="${PARAM_branch:-satcpt}"
inventory="${PARAM_inventory:-conf/contperf/inventory.${branch}.ini}"
manifest="${PARAM_manifest:-conf/contperf/manifest_SCA.zip}"

registrations_per_container_hosts=${PARAM_registrations_per_container_hosts:-5}
registrations_iterations=${PARAM_registrations_iterations:-20}
wait_interval=${PARAM_wait_interval:-50}
all_rex=${PARAM_all_rex:-false}
skip_util_reg_setup=${PARAM_skip_util_reg_setup:-false}

repo_sat_client_7="${PARAM_repo_sat_client_7:-http://mirror.example.com/Satellite_Client_7_x86_64/}"
repo_sat_client_8="${PARAM_repo_sat_client_8:-http://mirror.example.com/Satellite_Client_8_x86_64/}"

rhel_subscription="${PARAM_rhel_subscription:-Red Hat Enterprise Linux Server, Standard (Physical or Virtual Nodes)}"

dl="Default Location"

opts="--forks 100 -i $inventory"
opts_adhoc="$opts -e branch='$branch'"


if [ "$skip_util_reg_setup" != "true" ]; then
    section "Util: Checking environment"
    generic_environment_check

    section "Util: Prepare for Red Hat content"
    h_out "--no-headers --csv organization list --fields name" | grep --quiet "^{{ sat_org }}$" \
        || h 00-ensure-org.log "organization create --name '{{ sat_org }}'"
    h 00-ensure-loc-in-org.log "organization add-location --name '{{ sat_org }}' --location '$dl'"
    a 00-manifest-deploy.log -m copy -a "src=$manifest dest=/root/manifest-auto.zip force=yes" satellite6
    h 01-manifest-upload.log "subscription upload --file '/root/manifest-auto.zip' --organization '{{ sat_org }}'"
    skip_measurement='true' h 03-simple-content-access-disable.log "simple-content-access disable --organization '{{ sat_org }}'"
    s $wait_interval

    section "Util: Sync from CDN"
    h 20-manifest-refresh.log "subscription refresh-manifest --organization '{{ sat_org }}'"
    # h 20-reposet-enable-rhel7.log  "repository-set enable --organization '{{ sat_org }}' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server (RPMs)' --releasever '7Server' --basearch 'x86_64'"
    # h 20-repo-immediate-rhel7.log "repository update --organization '{{ sat_org }}' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server' --download-policy 'immediate'"
    # skip_measurement='false' h regs-20-repo-sync-rhel7.log "repository synchronize --organization '{{ sat_org }}' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server'" &
    # s $wait_interval
    h 20-reposet-enable-rhel8baseos.log  "repository-set enable --organization '{{ sat_org }}' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - BaseOS (RPMs)' --releasever '8' --basearch 'x86_64'"
    skip_measurement='false' h regs-20-repo-sync-rhel8baseos.log "repository synchronize --organization '{{ sat_org }}' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - BaseOS RPMs 8'" &
    s $wait_interval
    h 20-reposet-enable-rhel8appstream.log  "repository-set enable --organization '{{ sat_org }}' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - AppStream (RPMs)' --releasever '8' --basearch 'x86_64'"
    skip_measurement='false' h regs-20-repo-sync-rhel8appstream.log "repository synchronize --organization '{{ sat_org }}' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - AppStream RPMs 8'" &
    s $wait_interval

    section "Util: Sync Client repos"
    h 30-sat-client-product-create.log "product create --organization '{{ sat_org }}' --name SatClientProduct"
    h 30-repository-create-sat-client_7.log "repository create --organization '{{ sat_org }}' --product SatClientProduct --name SatClient7Repo --content-type yum --url '$repo_sat_client_7'"
    h 30-repository-sync-sat-client_7.log "repository synchronize --organization '{{ sat_org }}' --product SatClientProduct --name SatClient7Repo" &
    s $wait_interval
    h 30-repository-create-sat-client_8.log "repository create --organization '{{ sat_org }}' --product SatClientProduct --name SatClient8Repo --content-type yum --url '$repo_sat_client_8'"
    h 30-repository-sync-sat-client_8.log "repository synchronize --organization '{{ sat_org }}' --product SatClientProduct --name SatClient8Repo" &
    s $wait_interval

    wait
fi


section "Util: Prepare for registrations"
h_out "--no-headers --csv domain list --search 'name = {{ domain }}'" | grep --quiet '^[0-9]\+,' \
    || skip_measurement='true' h 42-domain-create.log "domain create --name '{{ domain }}' --organizations '{{ sat_org }}'"
tmp=$( mktemp )
h_out "--no-headers --csv location list --organization '{{ sat_org }}'" | grep '^[0-9]\+,' >$tmp
location_ids=$( cut -d ',' -f 1 $tmp | tr '\n' ',' | sed 's/,$//' )
skip_measurement='true' h 42-domain-update.log "domain update --name '{{ domain }}' --organizations '{{ sat_org }}' --location-ids '$location_ids'"

skip_measurement='true' h 43-ak-create.log "activation-key create --content-view '{{ sat_org }} View' --lifecycle-environment Library --name ActivationKey --organization '{{ sat_org }}'"
h_out "--csv subscription list --organization '{{ sat_org }}' --search 'name = \"$rhel_subscription\"'" >$logs/subs-list-rhel.log
rhel_subs_id=$( tail -n 1 $logs/subs-list-rhel.log | cut -d ',' -f 1 )
skip_measurement='true' h 43-ak-add-subs-rhel.log "activation-key add-subscription --organization '{{ sat_org }}' --name ActivationKey --subscription-id '$rhel_subs_id'"
h_out "--csv subscription list --organization '{{ sat_org }}' --search 'name = SatClientProduct'" >$logs/subs-list-client.log
client_subs_id=$( tail -n 1 $logs/subs-list-client.log | cut -d ',' -f 1 )
skip_measurement='true' h 43-ak-add-subs-client.log "activation-key add-subscription --organization '{{ sat_org }}' --name ActivationKey --subscription-id '$client_subs_id'"

tmp=$( mktemp )
h_out "--no-headers --csv capsule list --organization '{{ sat_org }}'" | grep '^[0-9]\+,' >$tmp
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
        || skip_measurement='true' h 44-subnet-create-$capsule_name.log "subnet create --name '$subnet_name' --ipam None --domains '{{ domain }}' --organization '{{ sat_org }}' --network 172.0.0.0 --mask 255.0.0.0 --location '$location_name'"
    subnet_id=$( h_out "--output yaml subnet info --name '$subnet_name'" | grep '^Id:' | cut -d ' ' -f 2 )
    skip_measurement='true' a 45-subnet-add-rex-capsule-$capsule_name.log \
      -m "ansible.builtin.uri" \
      -a "url=https://{{ groups['satellite6'] | first }}/api/v2/subnets/${subnet_id} force_basic_auth=true user={{ sat_user }} password={{ sat_pass }} method=PUT body_format=json body='{\"subnet\": {\"remote_execution_proxy_ids\": [\"${capsule_id}\"]}}'" \
      satellite6
    h_out "--no-headers --csv hostgroup list --search 'name = $hostgroup_name'" | grep --quiet '^[0-9]\+,' \
        || skip_measurement='true' ap 41-hostgroup-create-$capsule_name.log playbooks/satellite/hostgroup-create.yaml -e "organization='{{ sat_org }}' hostgroup_name=$hostgroup_name subnet_name=$subnet_name"
done

ap 44-generate-host-registration-command.log \
  -e "organization='{{ sat_org }}'" \
  -e "ak=ActivationKey" \
  playbooks/satellite/host-registration_generate-command.yaml

skip_measurement='true' ap 44-recreate-client-scripts.log \
  playbooks/satellite/client-scripts.yaml


section "Util: Register"
for i in $( seq $registrations_iterations ); do
    ap 50-register-$i.log playbooks/tests/registrations.yaml \
      -e "size=$registrations_per_container_hosts" \
      -e "registration_logs='../../$logs/50-register-container-host-client-logs'" \
      -e 're_register_failed_hosts=true' \
      -e "config_server_server_timeout=$registrations_config_server_server_timeout"
    e Register $logs/50-register-$i.log
    s $wait_interval
done


section "Util: Remote execution"
h 50-rex-set-via-ip.log "settings set --name remote_execution_connect_by_ip --value true"
a 51-rex-cleanup-know_hosts.log satellite6 -m "shell" -a "rm -rf /usr/share/foreman-proxy/.ssh/known_hosts*"

if [ "$all_rex" != "false" ]; then
    h 52-rex-ssh-date.log "job-invocation create --description-format 'Run %{command} (%{template_name})' --inputs command='date' --job-template 'Run Command - SSH Default' --search-query 'name ~ container'"
    s $wait_interval
    h 52-rex-ssh-sm-facts-update.log "job-invocation create --description-format 'Run %{command} (%{template_name})' --inputs command='subscription-manager facts --update' --job-template 'Run Command - SSH Default' --search-query 'name ~ container'"
    s $wait_interval
    h 52-rex-ssh-uploadprofile.log "job-invocation create --description-format 'Run %{command} (%{template_name})' --inputs command='dnf uploadprofile --force-upload' --job-template 'Run Command - SSH Default' --search-query 'name ~ container'"
    s $wait_interval
    h 52-rex-ansible-date.log "job-invocation create --description-format 'Run %{command} (%{template_name})' --inputs command='date' --job-template 'Run Command - Ansible Default' --search-query 'name ~ container'"
    s $wait_interval
fi

junit_upload
