#!/bin/bash

source experiment/run-library.sh

organization="${PARAM_organization:-Default Organization}"
manifest="${PARAM_manifest:-conf/contperf/manifest_SCA.zip}"
inventory="${PARAM_inventory:-conf/contperf/inventory.ini}"
private_key="${PARAM_private_key:-conf/contperf/id_rsa_perf}"
local_conf="${PARAM_local_conf:-conf/satperf.local.yaml}"

wait_interval=${PARAM_wait_interval:-50}
download_wait_interval=${PARAM_download_wait_interval:-30}
download_test_batches="${PARAM_download_test_batches:-1 2 3}"
bootstrap_additional_args="${PARAM_bootstrap_additional_args}"   # usually you want this empty

cdn_url_full="${PARAM_cdn_url_full:-https://cdn.redhat.com/}"

repo_sat_tools="${PARAM_repo_sat_tools:-http://mirror.example.com/Satellite_Tools_x86_64/}"

repo_sat_client_7="${PARAM_repo_sat_client_7:-http://mirror.example.com/Satellite_Client_7_x86_64/}"
repo_sat_client_8="${PARAM_repo_sat_client_8:-http://mirror.example.com/Satellite_Client_8_x86_64/}"

rhel_subscription="${PARAM_rhel_subscription:-Red Hat Enterprise Linux Server, Standard (Physical or Virtual Nodes)}"

repo_download_test="${PARAM_repo_download_test:-http://repos.example.com/pub/satperf/test_sync_repositories/repo*}"
repo_count_download_test="${PARAM_repo_count_download_test:-8}"
package_name_download_test="${PARAM_package_name_download_test:-foo*}"
workdir_url="${PARAM_workdir_url:-https://workdir-exporter.example.com/workspace}"
job_name="${PARAM_job_name:-Sat_Experiment}"
max_age_input="${PARAM_max_age_input:-19000}"
skip_down_setup="${PARAM_skip_down_setup:-false}"

dl="Default Location"

opts="--forks 100 -i $inventory --private-key $private_key"
opts_adhoc="$opts -e @conf/satperf.yaml -e @$local_conf"


section "Checking environment"
generic_environment_check


#If we already have setup ready - all repos synced, etc we can skip directly to registering and downloading batches. PLEASE DELETE ALL HOSTS FROM SATELLITE.
if [ "$skip_down_setup" != "true" ]; then
    section "Upload manifest"
    h_out "--no-headers --csv organization list --fields name" | grep --quiet "^$organization$" \
        || h regs-10-ensure-org.log "organization create --name '$organization'"
    h regs-10-ensure-loc-in-org.log "organization add-location --name '$organization' --location '$dl'"
    a regs-10-manifest-deploy.log -m copy -a "src=$manifest dest=/root/manifest-auto.zip force=yes" satellite6
    h regs-10-manifest-upload.log "subscription upload --file '/root/manifest-auto.zip' --organization '$organization'"
    s $wait_interval


    section "Sync from CDN"   # do not measure because of unpredictable network latency
    if [[ "$cdn_url_full" != 'https://cdn.redhat.com/' ]]; then
        h regs-20-set-cdn-stage.log "organization update --name '$organization' --redhat-repository-url '$cdn_url_full'"
    fi
    h regs-20-manifest-refresh.log "subscription refresh-manifest --organization '$organization'"

    h regs-20-reposet-enable-rhel7.log "repository-set enable --organization '$organization' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server (RPMs)' --releasever '7Server' --basearch 'x86_64'"
    h regs-20-repo-immediate-rhel7.log "repository update --organization '$organization' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server' --download-policy 'immediate'"
    h regs-20-repo-sync-rhel7.log "repository synchronize --organization '$organization' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server'"
    s $wait_interval


    section "Sync Tools repo"   # do not measure because of unpredictable network latency
    h regs-30-sat-tools-product-create.log "product create --organization '$organization' --name SatToolsProduct"
    h regs-30-repository-create-sat-tools.log "repository create --organization '$organization' --product SatToolsProduct --name SatToolsRepo --content-type yum --url '$repo_sat_tools'"
    h regs-30-repository-sync-sat-tools.log "repository synchronize --organization '$organization' --product SatToolsProduct --name SatToolsRepo"
    s $wait_interval


    section "Sync Client repos"   # do not measure because of unpredictable network latency
    h regs-30-sat-client-product-create.log "product create --organization '$organization' --name SatClientProduct"
    h regs-30-repository-create-sat-client_7.log "repository create --organization '$organization' --product SatClientProduct --name SatClient7Repo --content-type yum --url '$repo_sat_client_7'"
    h regs-30-repository-sync-sat-client_7.log "repository synchronize --organization '$organization' --product SatClientProduct --name SatClient7Repo"
    s $wait_interval
    h regs-30-repository-create-sat-client_8.log "repository create --organization '$organization' --product SatClientProduct --name SatClient8Repo --content-type yum --url '$repo_sat_client_8'"
    h regs-30-repository-sync-sat-client_8.log "repository synchronize --organization '$organization' --product SatClientProduct --name SatClient8Repo"
    s $wait_interval


    section "Sync Download Test repo"
    #h product-create-downtest.log "product create --organization '$organization' --name DownTestProduct"
    ap repository-create-downtest.log  \
      -e "repo_download_test=$repo_download_test" \
      -e "repo_count_download_test=$repo_count_download_test" \
      playbooks/tests/downloadtest-syncrepo.yaml
    # h repository-create-downtest.log "repository create --organization '$organization' --product DownTestProduct --name DownTestRepo --content-type yum --url '$repo_download_test'"
    # h repo-sync-downtest.log "repository synchronize --organization '$organization' --product DownTestProduct --name DownTestRepo"
    s $wait_interval


    section "Prepare for registrations"
    ap regs-40-recreate-client-scripts.log \
      -e "registration_hostgroup=hostgroup-for-{{ tests_registration_target }}" \
      playbooks/satellite/client-scripts.yaml # this detects OS, so need to run after we synces one

    h_out "--no-headers --csv domain list --search 'name = {{ domain }}'" | grep --quiet '^[0-9]\+,' \
        || h regs-40-domain-create.log "domain create --name '{{ domain }}' --organizations '$organization'"
    tmp=$( mktemp )
    h_out "--no-headers --csv location list --organization '$organization'" | grep '^[0-9]\+,' >$tmp
    location_ids=$( cut -d ',' -f 1 $tmp | tr '\n' ',' | sed 's/,$//' )
    h regs-40-domain-update.log "domain update --name '{{ domain }}' --organizations '$organization' --location-ids '$location_ids'"

    h regs-40-ak-create.log "activation-key create --content-view '$organization View' --lifecycle-environment Library --name ActivationKey --organization '$organization'"
    h_out "--csv subscription list --organization '$organization' --search 'name = SatToolsProduct'" >$logs/subs-list-tools.log
    tools_subs_id=$( tail -n 1 $logs/subs-list-tools.log | cut -d ',' -f 1 )
    skip_measurement='true' h 43-ak-add-subs-tools.log "activation-key add-subscription --organization '$organization' --name ActivationKey --subscription-id '$tools_subs_id'"
    h_out "--csv subscription list --organization '$organization' --search 'name = \"$rhel_subscription\"'" >$logs/subs-list-rhel.log
    rhel_subs_id=$( tail -n 1 $logs/subs-list-rhel.log | cut -d ',' -f 1 )
    skip_measurement='true' h 43-ak-add-subs-rhel.log "activation-key add-subscription --organization '$organization' --name ActivationKey --subscription-id '$rhel_subs_id'"
    h_out "--csv subscription list --organization '$organization' --search 'name = SatClientProduct'" >$logs/subs-list-client.log
    client_subs_id=$( tail -n 1 $logs/subs-list-client.log | cut -d ',' -f 1 )
    skip_measurement='true' h 43-ak-add-subs-client.log "activation-key add-subscription --organization '$organization' --name ActivationKey --subscription-id '$client_subs_id'"
    h regs-40-subs-list-downtest.log "--csv subscription list --organization '$organization' --search 'name = DownTestProduct'" >$logs/subs-list-downrepo.log
    down_test_subs_id=$( tail -n 1 $logs/subs-list-downrepo.log | cut -d ',' -f 1 )
    h regs-40-ak-add-subs-downtest.log "activation-key add-subscription --organization '$organization' --name ActivationKey --subscription-id '$organizationwn_test_subs_id'"

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
          || h regs-44-subnet-create-$capsule_name.log "subnet create --name '$subnet_name' --ipam None --domains '{{ domain }}' --organization '$organization' --network 172.0.0.0 --mask 255.0.0.0 --location '$location_name'"
        subnet_id=$( h_out "--output yaml subnet info --name '$subnet_name'" | grep '^Id:' | cut -d ' ' -f 2 )
        a regs-45-subnet-add-rex-capsule-$capsule_name.log satellite6 º \
          -m "ansible.builtin.shell" \
          -a "curl --silent --insecure -u {{ sat_user }}:{{ sat_pass }} -X PUT -H 'Accept: application/json' -H 'Content-Type: application/json' https://localhost//api/v2/subnets/$subnet_id -d '{\"subnet\": {\"remote_execution_proxy_ids\": [\"$capsule_id\"]}}'"
        h_out "--no-headers --csv hostgroup list --search 'name = $hostgroup_name'" | grep --quiet '^[0-9]\+,' \
          || ap regs-41-hostgroup-create-$capsule_name.log \
              -e "organization='$organization'" \
              -e "hostgroup_name=$hostgroup_name subnet_name=$subnet_name" \
              playbooks/satellite/hostgroup-create.yaml
    done
fi

skip_measurement='true' ap 44-recreate-client-scripts.log playbooks/satellite/client-scripts.yaml -e "registration_hostgroup=hostgroup-for-{{ tests_registration_target }}"


section "Register more and more"
ansible_container_hosts=$( ansible -i $inventory --list-hosts container_hosts,container_hosts 2>/dev/null | grep '^  hosts' | sed 's/^  hosts (\([0-9]\+\)):$/\1/' )
sum=0
for b in $download_test_batches; do
    let sum+=$( expr $b \* $ansible_container_hosts )
done
log "Going to register $sum hosts in total. Make sure there is enough hosts available."

iter=1
sum=0
totalclients=0
for batch in $download_test_batches; do
    ap regs-50-register-$iter-$batch.log \
      -e "size=$batch" \
      -e "tags=untagged,REG,REM bootstrap_activationkey='ActivationKey'" \
      -e "bootstrap_hostgroup='hostgroup-for-{{ tests_registration_target }}'" \
      -e "grepper='Register'" \
      -e "registration_logs='../../$logs/regs-50-register-container-host-client-logs'" \
      playbooks/tests/registrations.yaml
    e Register $logs/regs-50-register-$iter-$batch.log
    s $download_wait_interval
    let sum=$(($sum + $batch))
    let totalclients=$( expr $sum \* $ansible_container_hosts )
    ap clean-downrepo-50-$iter-$sum-$totalclients.log \
      playbooks/tests/downloadtest-cleanup.yaml
    ap downrepo-50-$iter-$sum-$totalclients-Download.log \
      -e "package_name_download_test=$package_name_download_test" \
      -e "max_age_task=$max_age_input" \
      playbooks/tests/downloadtest.yaml
    log "$(grep 'RESULT:' $logs/downrepo-50-$iter-$sum-$totalclients-Download.log)"
    let iter+=1
    s $wait_interval
done


section "Summary"
iter=1
sum=0
totalclients=0
for batch in $download_test_batches; do
    let sum=$(($sum + $batch))
    let totalclients=$( expr $sum \* $ansible_container_hosts )
    log "$(grep 'RESULT:' $logs/downrepo-50-$iter-$sum-$totalclients-Download.log)"
    let iter+=1
done

junit_upload
