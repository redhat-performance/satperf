#!/bin/bash

source experiment/run-library.sh

branch="${PARAM_branch:-satcpt}"
inventory="${PARAM_inventory:-conf/contperf/inventory.${branch}.ini}"
manifest="${PARAM_manifest:-conf/contperf/manifest_SCA.zip}"

cdn_url_full="${PARAM_cdn_url_full:-https://cdn.redhat.com/}"

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
opts_adhoc="$opts"


section "Checking environment"
generic_environment_check


#If we already have setup ready - all repos synced, etc we can skip directly to registering and downloading batches. PLEASE DELETE ALL HOSTS FROM SATELLITE.
if [ "$skip_down_setup" != "true" ]; then
    section "Sync Download Test repo"
    ap downtest-25-repository-create-downtest.log  \
      -e "organization='{{ sat_org }}'" \
      -e "download_test_repo_template='download_test_repo'" \
      -e "repo_download_test=$repo_download_test" \
      -e "repo_count_download_test=$repo_count_download_test" \
      playbooks/tests/downloadtest-syncrepo.yaml


    section "Push content to capsules"
    ap downtest-35-capsync-populate.log \
      -e "organization='{{ sat_org }}'" \
      playbooks/satellite/capsules-populate.yaml
    unset skip_measurement


    section "Prepare for registrations"
    h_out "--no-headers --csv domain list --search 'name = {{ domain }}'" | grep --quiet '^[0-9]\+,' \
      || h downtest-40-domain-create.log "domain create --name '{{ domain }}' --organizations '{{ sat_org }}'"
    
    tmp=$( mktemp )
    h_out "--no-headers --csv location list --organization '{{ sat_org }}'" | grep '^[0-9]\+,' >$tmp
    location_ids=$( cut -d ',' -f 1 $tmp | tr '\n' ',' | sed 's/,$//' )
    rm -f $tmp
    
    h downtest-40-domain-update.log "domain update --name '{{ domain }}' --organizations '{{ sat_org }}' --location-ids '$location_ids'"

    h downtest-40-ak-create.log "activation-key create --content-view '{{ sat_org }} View' --lifecycle-environment 'Library' --name '$ak' --organization '{{ sat_org }}'"

    h_out "--csv --no-headers activation-key product-content --organization '{{ sat_org }}' --content-access-mode-all true --name '$ak' --search 'name ~ download_test_repo' --fields label" >$logs/downtest-repo-label.log
    down_test_repo_label="$( tail -n 1 $logs/downtest-repo-label.log )"
    h downtest-40-ak-content-override-downtest.log "activation-key content-override --organization '{{ sat_org }}' --name '$ak' --content-label '$down_test_repo_label' --override-name 'enabled' --value 1"
fi

skip_measurement='true' ap downtest-44-generate-host-registration-command.log \
  -e "organization='{{ sat_org }}'" \
  -e "ak='$ak'" \
  playbooks/satellite/host-registration_generate-command.yaml

skip_measurement='true' ap downtest-44-recreate-client-scripts.log \
  playbooks/satellite/client-scripts.yaml


section "Register"
number_container_hosts=$( ansible $opts_adhoc --list-hosts container_hosts 2>/dev/null | grep '^  hosts' | sed 's/^  hosts (\([0-9]\+\)):$/\1/' )
number_containers_per_container_host=$( ansible $opts_adhoc -m debug -a "var=containers_count" container_hosts[0] | awk '/    "containers_count":/ {print $NF}' )
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
log "$(grep 'RESULT:' $logs/downtest-50-*-*-Download.log | sort -V)"


junit_upload
