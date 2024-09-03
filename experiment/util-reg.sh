#!/bin/bash

source experiment/run-library.sh

branch="${PARAM_branch:-satcpt}"
inventory="${PARAM_inventory:-conf/contperf/inventory.${branch}.ini}"
sat_version="${PARAM_sat_version:-stream}"
manifest="${PARAM_manifest:-conf/contperf/manifest_SCA.zip}"

registrations_per_container_hosts=${PARAM_registrations_per_container_hosts:-5}
registrations_iterations=${PARAM_registrations_iterations:-20}
all_rex=${PARAM_all_rex:-false}
skip_util_reg_setup=${PARAM_skip_util_reg_setup:-false}

repo_sat_client_7="${PARAM_repo_sat_client_7:-http://mirror.example.com/Satellite_Client_7_x86_64/}"
repo_sat_client_8="${PARAM_repo_sat_client_8:-http://mirror.example.com/Satellite_Client_8_x86_64/}"

rhel_subscription="${PARAM_rhel_subscription:-Red Hat Enterprise Linux Server, Standard (Physical or Virtual Nodes)}"

dl="Default Location"

opts="--forks 100 -i $inventory"
opts_adhoc="$opts"


if [ "$skip_util_reg_setup" != "true" ]; then
    section "Util: Checking environment"
    generic_environment_check

    section "Util: Prepare for Red Hat content"
    a 00-manifest-deploy.log -m copy -a "src=$manifest dest=/root/manifest-auto.zip force=yes" satellite6
    h 01-manifest-upload.log "subscription upload --file '/root/manifest-auto.zip' --organization '{{ sat_org }}'"
    skip_measurement='true' h 03-simple-content-access-disable.log "simple-content-access disable --organization '{{ sat_org }}'"

    section "Util: Sync from CDN"
    h 20-manifest-refresh.log "subscription refresh-manifest --organization '{{ sat_org }}'"
    # h 20-reposet-enable-rhel7.log  "repository-set enable --organization '{{ sat_org }}' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server (RPMs)' --releasever '7Server' --basearch 'x86_64'"
    # h 20-repo-immediate-rhel7.log "repository update --organization '{{ sat_org }}' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server' --download-policy 'immediate'"
    # skip_measurement='false' h regs-20-repo-sync-rhel7.log "repository synchronize --organization '{{ sat_org }}' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server'" &
    h 20-reposet-enable-rhel8baseos.log  "repository-set enable --organization '{{ sat_org }}' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - BaseOS (RPMs)' --releasever '8' --basearch 'x86_64'"
    skip_measurement='false' h regs-20-repo-sync-rhel8baseos.log "repository synchronize --organization '{{ sat_org }}' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - BaseOS RPMs 8'" &
    h 20-reposet-enable-rhel8appstream.log  "repository-set enable --organization '{{ sat_org }}' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - AppStream (RPMs)' --releasever '8' --basearch 'x86_64'"
    skip_measurement='false' h regs-20-repo-sync-rhel8appstream.log "repository synchronize --organization '{{ sat_org }}' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - AppStream RPMs 8'" &

    section "Util: Sync Client repos"
    h 30-sat-client-product-create.log "product create --organization '{{ sat_org }}' --name SatClientProduct"
    h 30-repository-create-sat-client_7.log "repository create --organization '{{ sat_org }}' --product SatClientProduct --name SatClient7Repo --content-type yum --url '$repo_sat_client_7'"
    h 30-repository-sync-sat-client_7.log "repository synchronize --organization '{{ sat_org }}' --product SatClientProduct --name SatClient7Repo" &
    h 30-repository-create-sat-client_8.log "repository create --organization '{{ sat_org }}' --product SatClientProduct --name SatClient8Repo --content-type yum --url '$repo_sat_client_8'"
    h 30-repository-sync-sat-client_8.log "repository synchronize --organization '{{ sat_org }}' --product SatClientProduct --name SatClient8Repo" &
    wait
fi


section "Util: Prepare for registrations"
h_out "--no-headers --csv domain list --search 'name = {{ domain }}'" | grep --quiet '^[0-9]\+,' \
    || skip_measurement='true' h 42-domain-create.log "domain create --name '{{ domain }}' --organizations '{{ sat_org }}'"
tmp="$( mktemp )"
h_out "--no-headers --csv location list --organization '{{ sat_org }}'" | grep '^[0-9]\+,' >$tmp
location_ids=$( cut -d ',' -f 1 $tmp | tr '\n' ',' | sed 's/,$//' )
rm -f $tmp
skip_measurement='true' h 42-domain-update.log "domain update --name '{{ domain }}' --organizations '{{ sat_org }}' --location-ids '$location_ids'"

skip_measurement='true' h 43-ak-create.log "activation-key create --content-view '{{ sat_org }} View' --lifecycle-environment Library --name ActivationKey --organization '{{ sat_org }}'"
h_out "--csv subscription list --organization '{{ sat_org }}' --search 'name = \"$rhel_subscription\"'" >$logs/subs-list-rhel.log
rhel_subs_id=$( tail -n 1 $logs/subs-list-rhel.log | cut -d ',' -f 1 )
skip_measurement='true' h 43-ak-add-subs-rhel.log "activation-key add-subscription --organization '{{ sat_org }}' --name ActivationKey --subscription-id '$rhel_subs_id'"
h_out "--csv subscription list --organization '{{ sat_org }}' --search 'name = SatClientProduct'" >$logs/subs-list-client.log
client_subs_id=$( tail -n 1 $logs/subs-list-client.log | cut -d ',' -f 1 )
skip_measurement='true' h 43-ak-add-subs-client.log "activation-key add-subscription --organization '{{ sat_org }}' --name ActivationKey --subscription-id '$client_subs_id'"

ap 44-generate-host-registration-command.log \
  -e "organization='{{ sat_org }}'" \
  -e "ak=ActivationKey" \
  -e "sat_version='$sat_version'" \
  playbooks/satellite/host-registration_generate-command.yaml

skip_measurement='true' ap 44-recreate-client-scripts.log \
  -e "ak=ActivationKey" \
  playbooks/satellite/client-scripts.yaml


section "Util: Register"
for i in $( seq $registrations_iterations ); do
    ap 50-register-$i.log \
      -e "size=$registrations_per_container_hosts" \
      -e "registration_logs='../../$logs/50-register-container-host-client-logs'" \
      -e 're_register_failed_hosts=true' \
      -e "sat_version='$sat_version'" \
      playbooks/tests/registrations.yaml
    e Register $logs/50-register-$i.log
done


section "Util: Remote execution"
h 50-rex-set-via-ip.log "settings set --name remote_execution_connect_by_ip --value true"
a 51-rex-cleanup-know_hosts.log satellite6 -m "shell" -a "rm -rf /usr/share/foreman-proxy/.ssh/known_hosts*"

if [ "$all_rex" != "false" ]; then
    h 52-rex-ssh-date.log "job-invocation create --description-format 'Run %{command} (%{template_name})' --inputs command='date' --job-template 'Run Command - SSH Default' --search-query 'name ~ container'"
    h 52-rex-ssh-sm-facts-update.log "job-invocation create --description-format 'Run %{command} (%{template_name})' --inputs command='subscription-manager facts --update' --job-template 'Run Command - SSH Default' --search-query 'name ~ container'"
    h 52-rex-ssh-uploadprofile.log "job-invocation create --description-format 'Run %{command} (%{template_name})' --inputs command='dnf uploadprofile --force-upload' --job-template 'Run Command - SSH Default' --search-query 'name ~ container'"
    h 52-rex-ansible-date.log "job-invocation create --description-format 'Run %{command} (%{template_name})' --inputs command='date' --job-template 'Run Command - Ansible Default' --search-query 'name ~ container'"
fi


junit_upload
