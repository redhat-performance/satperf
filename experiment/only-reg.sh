#!/bin/bash

source experiment/run-library.sh

branch="${PARAM_branch:-satcpt}"
inventory="${PARAM_inventory:-conf/contperf/inventory.${branch}.ini}"
sat_version="${PARAM_sat_version:-stream}"
manifest="${PARAM_manifest:-conf/contperf/manifest_SCA.zip}"

registrations_per_docker_hosts=${PARAM_registrations_per_docker_hosts:-5}
registrations_iterations=${PARAM_registrations_iterations:-20}

repo_sat_client_7="${PARAM_repo_sat_client_7:-http://mirror.example.com/Satellite_Client_7_x86_64/}"
repo_sat_client_8="${PARAM_repo_sat_client_8:-http://mirror.example.com/Satellite_Client_8_x86_64/}"

rhel_subscription="${PARAM_rhel_subscription:-Red Hat Enterprise Linux Server, Standard (Physical or Virtual Nodes)}"

dl="Default Location"

opts="--forks 100 -i $inventory"
opts_adhoc="$opts"


section "Util: Prepare for Red Hat content"
a 00-manifest-deploy.log -m copy -a "src=$manifest dest=/root/manifest-auto.zip force=yes" satellite6
h 01-manifest-upload.log "subscription upload --file '/root/manifest-auto.zip' --organization '{{ sat_org }}'"
h 03-manifest-refresh.log "subscription refresh-manifest --organization '{{ sat_org }}'"


section "Util: Sync Client repos"
h client-product-create.log "product create --organization '{{ sat_org }}' --name SatClientProduct"
h repository-create-sat-client_7.log "repository create --organization '{{ sat_org }}' --product SatClientProduct --name SatClient7Repo --content-type yum --url '$repo_sat_client_7'"
h repository-sync-sat-client_7.log "repository synchronize --organization '{{ sat_org }}' --product SatClientProduct --name SatClient7Repo"
h repository-create-sat-client_8.log "repository create --organization '{{ sat_org }}' --product SatClientProduct --name SatClient8Repo --content-type yum --url '$repo_sat_client_8'"
h repository-sync-sat-client_8.log "repository synchronize --organization '{{ sat_org }}' --product SatClientProduct --name SatClient8Repo"


h regs-40-ak-create.log "activation-key create --content-view '{{ sat_org }} View' --lifecycle-environment Library --name ActivationKey --organization '{{ sat_org }}'"
h_out "--csv subscription list --organization '{{ sat_org }}' --search 'name = \"$rhel_subscription\"'" >$logs/subs-list-rhel.log
rhel_subs_id=$( tail -n 1 $logs/subs-list-rhel.log | cut -d ',' -f 1 )
skip_measurement='true' h 43-ak-add-subs-rhel.log "activation-key add-subscription --organization '{{ sat_org }}' --name ActivationKey --subscription-id '$rhel_subs_id'"
h_out "--csv subscription list --organization '{{ sat_org }}' --search 'name = SatClientProduct'" >$logs/subs-list-client.log
client_subs_id=$( tail -n 1 $logs/subs-list-client.log | cut -d ',' -f 1 )
skip_measurement='true' h 43-ak-add-subs-client.log "activation-key add-subscription --organization '{{ sat_org }}' --name ActivationKey --subscription-id '$client_subs_id'"

section "Util: Prepare for registrations"
h_out "--no-headers --csv domain list --search 'name = {{ domain }}'" | grep --quiet '^[0-9]\+,' \
    || h 42-domain-create.log "domain create --name '{{ domain }}' --organizations '{{ sat_org }}'"
tmp=$( mktemp )
h_out "--no-headers --csv location list --organization '{{ sat_org }}'" | grep '^[0-9]\+,' >$tmp
location_ids=$( cut -d ',' -f 1 $tmp | tr '\n' ',' | sed 's/,$//' )
h 42-domain-update.log "domain update --name '{{ domain }}' --organizations '{{ sat_org }}' --location-ids '$location_ids'"

ap 44-generate-host-registration-command.log \
  -e "organization='{{ sat_org }}'" \
  -e "ak=ActivationKey" \
  playbooks/satellite/host-registration_generate-command.yaml

skip_measurement='true' ap 44-recreate-client-scripts.log \
  playbooks/satellite/client-scripts.yaml


section "Util: Register"
for i in $( seq $registrations_iterations ); do
    ap 44-register-$i.log \
      -e "size=$registrations_per_docker_hosts" \
      -e "registration_logs='../../$logs/44-register-docker-host-client-logs'" \
      -e "sat_version='$sat_version'" \
      playbooks/tests/registrations.yaml
    e Register $logs/44-register-$i.log
done


junit_upload
