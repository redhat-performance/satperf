#!/bin/bash

source experiment/run-library.sh

branch="${PARAM_branch:-satcpt}"
inventory="${PARAM_inventory:-conf/contperf/inventory.${branch}.ini}"
manifest="${PARAM_manifest:-conf/contperf/manifest_SCA.zip}"

wait_interval=${PARAM_wait_interval:-50}
registrations_batches="${PARAM_registrations_batches:-1 2 3}"
registrations_config_server_server_timeout="${PARAM_registrations_config_server_server_timeout:-}"   # empty means to use default
bootstrap_additional_args="${PARAM_bootstrap_additional_args}"   # usually you want this empty

cdn_url_full="${PARAM_cdn_url_full:-https://cdn.redhat.com/}"

repo_sat_client_7="${PARAM_repo_sat_client_7:-http://mirror.example.com/Satellite_Client_7_x86_64/}"
repo_sat_client_8="${PARAM_repo_sat_client_8:-http://mirror.example.com/Satellite_Client_8_x86_64/}"

rhel_subscription="${PARAM_rhel_subscription:-Red Hat Enterprise Linux Server, Standard (Physical or Virtual Nodes)}"

dl="Default Location"

opts="--forks 100 -i $inventory"
opts_adhoc="$opts -e branch='$branch'"


section "Checking environment"
generic_environment_check


export skip_measurement='true'
section "Upload manifest"
h_out "--no-headers --csv organization list --fields name" | grep --quiet "^{{ sat_org }}$" \
  || h regs-10-ensure-org.log "organization create --name '{{ sat_org }}'"
h regs-10-ensure-loc-in-org.log "organization add-location --name '{{ sat_org }}' --location '$dl'"
a regs-10-manifest-deploy.log -m copy -a "src=$manifest dest=/root/manifest-auto.zip force=yes" satellite6
h regs-10-manifest-upload.log "subscription upload --file '/root/manifest-auto.zip' --organization '{{ sat_org }}'"
h regs-10-simple-content-access-disable.log "simple-content-access disable --organization '{{ sat_org }}'"
s $wait_interval
unset skip_measurement


export skip_measurement='true'
section "Sync from CDN"   # do not measure because of unpredictable network latency
h regs-20-set-cdn-stage.log "organization update --name '{{ sat_org }}' --redhat-repository-url '$cdn_url_full'"
h regs-20-manifest-refresh.log "subscription refresh-manifest --organization '{{ sat_org }}'"
h regs-20-reposet-enable-rhel7.log  "repository-set enable --organization '{{ sat_org }}' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server (RPMs)' --releasever '7Server' --basearch 'x86_64'"
h regs-20-repo-immediate-rhel7.log "repository update --organization '{{ sat_org }}' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server' --download-policy 'immediate'"
skip_measurement='false' h regs-20-repo-sync-rhel7.log "repository synchronize --organization '{{ sat_org }}' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server'"
s $wait_interval
h regs-20-reposet-enable-rhel8baseos.log  "repository-set enable --organization '{{ sat_org }}' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - BaseOS (RPMs)' --releasever '8' --basearch 'x86_64'"
skip_measurement='false' h regs-20-repo-sync-rhel8baseos.log "repository synchronize --organization '{{ sat_org }}' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - BaseOS RPMs 8'"
s $wait_interval
h regs-20-reposet-enable-rhel8appstream.log  "repository-set enable --organization '{{ sat_org }}' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - AppStream (RPMs)' --releasever '8' --basearch 'x86_64'"
skip_measurement='false' h regs-20-repo-sync-rhel8appstream.log "repository synchronize --organization '{{ sat_org }}' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - AppStream RPMs 8'"
s $wait_interval

section "Sync Client repos"   # do not measure because of unpredictable network latency
h regs-30-sat-client-product-create.log "product create --organization '{{ sat_org }}' --name SatClientProduct"
h regs-30-repository-create-sat-client_7.log "repository create --organization '{{ sat_org }}' --product SatClientProduct --name SatClient7Repo --content-type yum --url '$repo_sat_client_7'"
skip_measurement='false' h regs-30-repository-sync-sat-client_7.log "repository synchronize --organization '{{ sat_org }}' --product SatClientProduct --name SatClient7Repo"
s $wait_interval
h regs-30-repository-create-sat-client_8.log "repository create --organization '{{ sat_org }}' --product SatClientProduct --name SatClient8Repo --content-type yum --url '$repo_sat_client_8'"
skip_measurement='false' h regs-30-repository-sync-sat-client_8.log "repository synchronize --organization '{{ sat_org }}' --product SatClientProduct --name SatClient8Repo"
s $wait_interval
unset skip_measurement


export skip_measurement='true'
section "Prepare for registrations"
h_out "--no-headers --csv domain list --search 'name = {{ domain }}'" | grep --quiet '^[0-9]\+,' \
    || h regs-42-domain-create.log "domain create --name '{{ domain }}' --organizations '{{ sat_org }}'"
tmp=$( mktemp )
h_out "--no-headers --csv location list --organization '{{ sat_org }}'" | grep '^[0-9]\+,' >$tmp
location_ids=$( cut -d ',' -f 1 $tmp | tr '\n' ',' | sed 's/,$//' )
h regs-42-domain-update.log "domain update --name '{{ domain }}' --organizations '{{ sat_org }}' --location-ids '$location_ids'"

h regs-43-ak-create.log "activation-key create --content-view '{{ sat_org }} View' --lifecycle-environment Library --name ActivationKey --organization '{{ sat_org }}'"
h_out "--csv subscription list --organization '{{ sat_org }}' --search 'name = \"$rhel_subscription\"'" >$logs/subs-list-rhel.log
rhel_subs_id=$( tail -n 1 $logs/subs-list-rhel.log | cut -d ',' -f 1 )
h regs-43-ak-add-subs-rhel.log "activation-key add-subscription --organization '{{ sat_org }}' --name ActivationKey --subscription-id '$rhel_subs_id'"
h_out "--csv subscription list --organization '{{ sat_org }}' --search 'name = SatClientProduct'" >$logs/subs-list-client.log
client_subs_id=$( tail -n 1 $logs/subs-list-client.log | cut -d ',' -f 1 )
h regs-43-ak-add-subs-client.log "activation-key add-subscription --organization '{{ sat_org }}' --name ActivationKey --subscription-id '$client_subs_id'"

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
      || h regs-44-subnet-create-$capsule_name.log "subnet create --name '$subnet_name' --ipam None --domains '{{ domain }}' --organization '{{ sat_org }}' --network 172.0.0.0 --mask 255.0.0.0 --location '$location_name'"
    subnet_id=$( h_out "--output yaml subnet info --name '$subnet_name'" | grep '^Id:' | cut -d ' ' -f 2 )
    a regs-45-subnet-add-rex-capsule-$capsule_name.log satellite6 -m "shell" -a "curl --silent --insecure -u {{ sat_user }}:{{ sat_pass }} -X PUT -H 'Accept: application/json' -H 'Content-Type: application/json' https://localhost//api/v2/subnets/$subnet_id -d '{\"subnet\": {\"remote_execution_proxy_ids\": [\"$capsule_id\"]}}'"
    h_out "--no-headers --csv hostgroup list --search 'name = $hostgroup_name'" | grep --quiet '^[0-9]\+,' \
      || ap regs-41-hostgroup-create-$capsule_name.log \
         -e "organization='{{ sat_org }}'" \
         -e "hostgroup_name=$hostgroup_name subnet_name=$subnet_name" \
         playbooks/satellite/hostgroup-create.yaml
done

ap 44-generate-host-registration-command.log \
  -e "organization='{{ sat_org }}'" \
  -e "ak=ActivationKey" \
  playbooks/satellite/host-registration_generate-command.yaml

ap 44-recreate-client-scripts.log \
  playbooks/satellite/client-scripts.yaml
unset skip_measurement


section "Register more and more"
ansible_container_hosts=$( ansible $opts_adhoc --list-hosts container_hosts 2>/dev/null | grep '^  hosts' | sed 's/^  hosts (\([0-9]\+\)):$/\1/' )
sum=0
for b in $registrations_batches; do
    let sum+=$( expr $b \* $ansible_container_hosts )
done

log "Going to register $sum hosts in total. Make sure there is enough hosts available."

iter=1
for batch in $registrations_batches; do
    ap regs-50-register-$iter-$batch.log \
      -e "size=$batch" \
      -e "registration_logs='../../$logs/regs-50-register-container-host-client-logs'" \
      -e "config_server_server_timeout=$registrations_config_server_server_timeout" \
      -e "method=clients_host-registration" \
      playbooks/tests/registrations.yaml
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


section "Sosreport"
skip_measurement='true' ap sosreporter-gatherer.log playbooks/satellite/sosreport_gatherer.yaml -e "sosreport_gatherer_local_dir='../../$logs/sosreport/'"

junit_upload
