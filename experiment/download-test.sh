#!/bin/bash

source experiment/run-library.sh

manifest="${PARAM_manifest:-conf/contperf/manifest.zip}"
inventory="${PARAM_inventory:-conf/contperf/inventory.ini}"
private_key="${PARAM_private_key:-conf/contperf/id_rsa_perf}"

wait_interval=${PARAM_wait_interval:-50}
download_test_batches="${PARAM_download_test_batches:-1 2 3}"
bootstrap_additional_args="${PARAM_bootstrap_additional_args}"   # usually you want this empty

cdn_url_full="${PARAM_cdn_url_full:-https://cdn.redhat.com/}"

repo_sat_tools="${PARAM_repo_sat_tools:-http://mirror.example.com/Satellite_Tools_x86_64/}"

repo_download_test="${PARAM_repo_download_test:-http://perf54.perf.lab.eng.bos.redhat.com/pub/satperf/test_sync_repositories/repo1/}"

do="Default Organization"
dl="Default Location"

opts="--forks 100 -i $inventory --private-key $private_key"
opts_adhoc="$opts --user root -e @conf/satperf.yaml -e @conf/satperf.local.yaml"


section "Checking environment"
generic_environment_check


section "Upload manifest"
h regs-10-ensure-loc-in-org.log "organization add-location --name 'Default Organization' --location 'Default Location'"
a regs-10-manifest-deploy.log -m copy -a "src=$manifest dest=/root/manifest-auto.zip force=yes" satellite6
h regs-10-manifest-upload.log "subscription upload --file '/root/manifest-auto.zip' --organization '$do'"
s $wait_interval


section "Sync from CDN"   # do not measure because of unpredictable network latency
h regs-20-set-cdn-stage.log "organization update --name 'Default Organization' --redhat-repository-url '$cdn_url_full'"
h regs-20-reposet-enable-rhel7.log  "repository-set enable --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server (RPMs)' --releasever '7Server' --basearch 'x86_64'"
h regs-20-repo-immediate-rhel7.log "repository update --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server' --download-policy 'immediate'"
h regs-20-repo-sync-rhel7.log "repository synchronize --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server'"
s $wait_interval


section "Sync Tools repo"   # do not measure because of unpredictable network latency
h regs-30-sat-tools-product-create.log "product create --organization '$do' --name SatToolsProduct"
h regs-30-repository-create-sat-tools.log "repository create --organization '$do' --product SatToolsProduct --name SatToolsRepo --content-type yum --url '$repo_sat_tools'"
h regs-30-repository-sync-sat-tools.log "repository synchronize --organization '$do' --product SatToolsProduct --name SatToolsRepo"
s $wait_interval

section "Sync Download Test repo"
h product-create-downtest.log "product create --organization '$do' --name down_test_product"
h repository-create-downtest.log "repository create --organization '$do' --product down_test_product --name down_test_repo --content-type yum --url '$repo_download_test'"
h repo-sync-downtest.log "repository synchronize --organization '$do' --product down_test_product --name down_test_repo"
s $wait_interval

section "Prepare for registrations"
ap regs-40-recreate-client-scripts.log playbooks/satellite/client-scripts.yaml   # this detects OS, so need to run after we synces one

h_out "--no-headers --csv domain list --search 'name = {{ client_domain }}'" | grep --quiet '^[0-9]\+,' \
    || h regs-40-domain-create.log "domain create --name '{{ client_domain }}' --organizations '$do'"
tmp=$( mktemp )
h_out "--no-headers --csv location list --organization '$do'" | grep '^[0-9]\+,' >$tmp
location_ids=$( cut -d ',' -f 1 $tmp | tr '\n' ',' | sed 's/,$//' )
h regs-40-domain-update.log "domain update --name '{{ client_domain }}' --organizations '$do' --location-ids '$location_ids'"

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
        || h regs-44-subnet-create-$capsule_name.log "subnet create --name '$subnet_name' --ipam None --domains '{{ client_domain }}' --organization '$do' --network 172.0.0.0 --mask 255.0.0.0 --location '$location_name'"
    subnet_id=$( h_out "--output yaml subnet info --name '$subnet_name'" | grep '^Id:' | cut -d ' ' -f 2 )
    a regs-45-subnet-add-rex-capsule-$capsule_name.log satellite6 -m "shell" -a "curl --silent --insecure -u {{ sat_user }}:{{ sat_pass }} -X PUT -H 'Accept: application/json' -H 'Content-Type: application/json' https://localhost//api/v2/subnets/$subnet_id -d '{\"subnet\": {\"remote_execution_proxy_ids\": [\"$capsule_id\"]}}'"
    h_out "--no-headers --csv hostgroup list --search 'name = $hostgroup_name'" | grep --quiet '^[0-9]\+,' \
        || h regs-41-hostgroup-create-$capsule_name.log "hostgroup create --content-view 'Default Organization View' --lifecycle-environment Library --name '$hostgroup_name' --query-organization '$do' --subnet '$subnet_name'"
done

h regs-40-ak-create.log "activation-key create --content-view 'Default Organization View' --lifecycle-environment Library --name ActivationKey --organization '$do'"
h regs-40-subs-list-tools.log "--csv subscription list --organization '$do' --search 'name = SatToolsProduct'"
tools_subs_id=$( tail -n 1 $logs/regs-40-subs-list-tools.log | cut -d ',' -f 1 )
h regs-40-ak-add-subs-tools.log "activation-key add-subscription --organization '$do' --name ActivationKey --subscription-id '$tools_subs_id'"
h regs-40-subs-list-employee.log "--csv subscription list --organization '$do' --search 'name = \"Employee SKU\"'"
employee_subs_id=$( tail -n 1 $logs/regs-40-subs-list-employee.log | cut -d ',' -f 1 )
h regs-40-ak-add-subs-employee.log "activation-key add-subscription --organization '$do' --name ActivationKey --subscription-id '$employee_subs_id'"
h regs-40-subs-list-downtest.log "--csv subscription list --organization '$do' --search 'name = \"down_test_repo\"'"
down_test_subs_id=$( tail -n 1 $logs/regs-subs-list-downtest.log | cut -d ',' -f 1 )
h regs-40-ak-add-subs-downtest.log "activation-key add-subscription --organization '$do' --name ActivationKey --subscription-id '$down_test_subs_id'"


section "Register more and more"
ansible_docker_hosts=$( ansible -i $inventory --list-hosts docker_hosts 2>/dev/null | grep '^  hosts' | sed 's/^  hosts (\([0-9]\+\)):$/\1/' )
sum=0
for b in $download_test_batches; do
    let sum+=$( expr $b \* $ansible_docker_hosts )
done
log "Going to register $sum hosts in total. Make sure there is enough hosts available."

iter=1
sum=0
for batch in $download_test_batches; do
    ap regs-50-register-$iter-$batch.log playbooks/tests/registrations.yaml -e "size=$batch tags=untagged,REG,REM bootstrap_activationkey='ActivationKey' bootstrap_hostgroup='hostgroup-for-{{ tests_registration_target }}' grepper='Register' registration_logs='../../$logs/regs-50-register-docker-host-client-logs'"
    e Register $logs/regs-50-register-$iter-$batch.log
    let iter+=1
    let sum=$(($sum + $batch))
    ap downrepo-50-$iter-$sum.log playbooks/tests/downloadtest.yaml
    s $wait_interval
done

section "Summary"
# iter=1
# for batch in $registrations_batches; do
#     log "$( experiment/reg-average.py Register $logs/regs-50-register-$iter-$batch.log | tail -n 1 )"
#     let iter+=1
# done

junit_upload
