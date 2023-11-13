#!/bin/bash

source experiment/run-library.sh

organization="${PARAM_organization:-Default Organization}"
manifest="${PARAM_manifest:-conf/contperf/manifest_SCA.zip}"
inventory="${PARAM_inventory:-conf/contperf/inventory.ini}"
private_key="${PARAM_private_key:-conf/contperf/id_rsa_perf}"
local_conf="${PARAM_local_conf:-conf/satperf.local.yaml}"

download_test_batches="${PARAM_download_test_batches:-1 2 3}"
bootstrap_additional_args="${PARAM_bootstrap_additional_args}"   # usually you want this empty

cdn_url_full="${PARAM_cdn_url_full:-https://cdn.redhat.com/}"

repo_sat_client_7="${PARAM_repo_sat_client_7:-http://mirror.example.com/Satellite_Client_7_x86_64/}"
repo_sat_client_8="${PARAM_repo_sat_client_8:-http://mirror.example.com/Satellite_Client_8_x86_64/}"

rhel_subscription="${PARAM_rhel_subscription:-Red Hat Enterprise Linux Server, Standard (Physical or Virtual Nodes)}"

ak="${PARAM_ak:-ActivationKey}"

expected_concurrent_registrations=${PARAM_expected_concurrent_registrations:-64}
initial_batch=${PARAM_initial_batch:-1}

repo_download_test="${PARAM_repo_download_test:-http://repos.example.com/pub/satperf/test_sync_repositories/repo*}"
repo_count_download_test="${PARAM_repo_count_download_test:-8}"
package_name_download_test="${PARAM_package_name_download_test:-foo*}"
workdir_url="${PARAM_workdir_url:-https://workdir-exporter.example.com/workspace}"
job_name="${PARAM_job_name:-Sat_Experiment}"
max_age_input="${PARAM_max_age_input:-19000}"

skip_down_setup="${PARAM_skip_down_setup:-false}"

dl="Default Location"

opts="--forks 100 -i $inventory"
opts_adhoc="$opts -e @conf/satperf.yaml -e @$local_conf"


section "Checking environment"
generic_environment_check


#If we already have setup ready - all repos synced, etc we can skip directly to registering and downloading batches. PLEASE DELETE ALL HOSTS FROM SATELLITE.
if [ "$skip_down_setup" != "true" ]; then
    section "Sync Download Test repo"
    ap downtest-25-repository-create-downtest.log  \
      -e "download_test_repo_template='download_test_repo'" \
      -e "repo_download_test=$repo_download_test" \
      -e "repo_count_download_test=$repo_count_download_test" \
      playbooks/tests/downloadtest-syncrepo.yaml


    section "Push content to capsules"
    ap downtest-35-capsync-populate.log \
      -e "organization='$organization'" \
      playbooks/satellite/capsules-populate.yaml
    unset skip_measurement


    section "Prepare for registrations"
    h_out "--no-headers --csv domain list --search 'name = {{ domain }}'" | grep --quiet '^[0-9]\+,' \
      || h downtest-40-domain-create.log "domain create --name '{{ domain }}' --organizations '$organization'"
    tmp=$( mktemp )
    h_out "--no-headers --csv location list --organization '$organization'" | grep '^[0-9]\+,' >$tmp
    location_ids=$( cut -d ',' -f 1 $tmp | tr '\n' ',' | sed 's/,$//' )
    rm -f $tmp
    h downtest-40-domain-update.log "domain update --name '{{ domain }}' --organizations '$organization' --location-ids '$location_ids'"

    h downtest-40-ak-create.log "activation-key create --content-view '$organization View' --lifecycle-environment 'Library' --name '$ak' --organization '$organization'"

    h_out "--csv --no-headers activation-key product-content --organization '$organization' --content-access-mode-all true --name '$ak' --search 'name ~ download_test_repo' --fields label" >$logs/downtest-repo-label.log
    down_test_repo_label="$( tail -n 1 $logs/downtest-repo-label.log )"
    h downtest-40-ak-content-override-downtest.log "activation-key content-override --organization '$organization' --name '$ak' --content-label '$down_test_repo_label' --override-name 'enabled' --value 1"


    tmp=$( mktemp )
    h_out "--no-headers --csv capsule list --organization '$organization'" | grep '^[0-9]\+,' >$tmp
    rows="$( cut -d ' ' -f 1 $tmp )"
    rm -f $tmp
    for row in $rows; do
        capsule_id="$( echo "$row" | cut -d ',' -f 1 )"
        capsule_name="$( echo "$row" | cut -d ',' -f 2 )"
        subnet_name="subnet-for-${capsule_name}"
        if [ "$capsule_id" -eq 1 ]; then
            location_name="$dl"
        else
            location_name="Location for $capsule_name"
        fi

        h_out "--no-headers --csv subnet list --search 'name = $subnet_name'" | grep --quiet '^[0-9]\+,' \
          || h downtest-44-subnet-create-${capsule_name}.log "subnet create --name '$subnet_name' --ipam None --domains '{{ domain }}' --organization '$organization' --network 172.0.0.0 --mask 255.0.0.0 --location '$location_name'"

        subnet_id="$( h_out "--output yaml subnet info --name '$subnet_name'" | grep '^Id:' | cut -d ' ' -f 2 )"
        a downtest-45-subnet-add-rex-capsule-${capsule_name}.log \
          -m "ansible.builtin.uri" \
          -a "url=https://{{ groups['satellite6'] | first }}/api/v2/subnets/${subnet_id} force_basic_auth=true user={{ sat_user }} password={{ sat_pass }} method=PUT body_format=json body='{\"subnet\": {\"remote_execution_proxy_ids\": [\"${capsule_id}\"]}}'" \
          satellite6
    done
fi


skip_measurement='true' ap downtest-44-generate-host-registration-command.log \
  -e "ak='$ak'" \
  playbooks/satellite/host-registration_generate-command.yaml
skip_measurement='true' ap downtest-44-recreate-client-scripts.log \
  playbooks/satellite/client-scripts.yaml


section "Register"
number_container_hosts=$( ansible -i $inventory --list-hosts container_hosts 2>/dev/null | grep '^  hosts' | sed 's/^  hosts (\([0-9]\+\)):$/\1/' )
number_containers_per_container_host=$( ansible -i $inventory -m debug -a "var=containers_count" container_hosts[0] | awk '/    "containers_count":/ {print $NF}' )
total_number_containers=$(( number_container_hosts * number_containers_per_container_host ))
concurrent_registrations_per_container_host=$(( expected_concurrent_registrations / number_container_hosts ))
real_concurrent_registrations=$(( concurrent_registrations_per_container_host * number_container_hosts ))
registration_iterations=$(( ( total_number_containers + real_concurrent_registrations - 1 ) / real_concurrent_registrations )) # We want ceiling rounding: Ceiling( X / Y ) = ( X + Y – 1 ) / Y

log "Going to register $total_number_containers hosts: $concurrent_registrations_per_container_host hosts per container host ($number_container_hosts available) in $(( registration_iterations + 1 )) batches."

for (( batch=initial_batch, total_clients=real_concurrent_registrations; batch <= ( registration_iterations + 1 ); batch++, total_clients += real_concurrent_registrations )); do
    ap downtest-50-register-${batch}-${total_clients}.log \
      -e "size='${concurrent_registrations_per_container_host}'" \
      -e "registration_logs='../../$logs/44b-register-container-host-client-logs'" \
      -e 're_register_failed_hosts=true' \
      playbooks/tests/registrations.yaml
    e Register $logs/downtest-50-register-${batch}-${total_clients}.log

    job_template_ssh_default='Run Command - Script Default'

    ap downtest-50-${batch}-${total_clients}-Download.log \
      -e "job_template_ssh_default='$job_template_ssh_default'" \
      -e "package_name_download_test=$package_name_download_test" \
      -e "max_age_task=$max_age_input" \
      playbooks/tests/downloadtest.yaml
    log "$(grep 'RESULT:' $logs/downtest-50-${batch}-${total_clients}-Download.log)"
done


section "Summary"
log "$(grep 'RESULT:' $logs/downtest-50-*-*-Download.log)"


junit_upload
