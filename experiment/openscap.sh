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

workdir_url="${PARAM_workdir_url:-https://workdir-exporter-jenkins-csb-perf.apps.ocp-c1.prod.psi.redhat.com/workspace}"
job_name="${PARAM_job_name:-Sat_Experiment}"
max_age_input="${PARAM_max_age_input:-19000}"
proxy_id="${PARAM_proxy_id:-set-in-doit-sh}"

do="Default Organization"
dl="Default Location"

opts="--forks 100 -i $inventory --private-key $private_key"
opts_adhoc="$opts --user root -e @conf/satperf.yaml -e @conf/satperf.local.yaml"


section "Checking environment"
generic_environment_check

export skip_measurement='true'

section "Upload manifest"
h regs-10-ensure-loc-in-org.log "organization add-location --name 'Default Organization' --location 'Default Location'"
a regs-10-manifest-deploy.log -m copy -a "src=$manifest dest=/root/manifest-auto.zip force=yes" satellite6
h regs-10-manifest-upload.log "subscription upload --file '/root/manifest-auto.zip' --organization '$do'"
skip_measurement='true' h 03-simple-content-access-disable.log "simple-content-access disable --organization '$do'"
s $wait_interval


section "Sync from CDN"   # do not measure because of unpredictable network latency
h regs-20-set-cdn-stage.log "organization update --name 'Default Organization' --redhat-repository-url '$cdn_url_full'"
h regs-20-reposet-enable-rhel7.log  "repository-set enable --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server (RPMs)' --releasever '7Server' --basearch 'x86_64'"
h regs-20-repo-immediate-rhel7.log "repository update --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server' --download-policy 'immediate'"
skip_measurement='false' h regs-20-repo-sync-rhel7.log "repository synchronize --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server'"
s $wait_interval
h regs-20-reposet-enable-rhel8baseos.log  "repository-set enable --organization '$do' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - BaseOS (RPMs)' --releasever '8' --basearch 'x86_64'"
skip_measurement='false' h regs-20-repo-sync-rhel8baseos.log "repository synchronize --organization '$do' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - BaseOS RPMs 8'"
s $wait_interval
h regs-20-reposet-enable-rhel8appstream.log  "repository-set enable --organization '$do' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - AppStream (RPMs)' --releasever '8' --basearch 'x86_64'"
skip_measurement='false' h regs-20-repo-sync-rhel8appstream.log "repository synchronize --organization '$do' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - AppStream RPMs 8'"
s $wait_interval

section "Sync Tools repo"   # do not measure because of unpredictable network latency
h regs-30-sat-tools-product-create.log "product create --organization '$do' --name SatToolsProduct"
h regs-30-repository-create-sat-tools.log "repository create --organization '$do' --product SatToolsProduct --name SatToolsRepo --content-type yum --url '$repo_sat_tools'"
skip_measurement='false' h regs-30-repository-sync-sat-tools.log "repository synchronize --organization '$do' --product SatToolsProduct --name SatToolsRepo"
s $wait_interval


section "Prepare for registrations"
ap regs-40-recreate-client-scripts.log playbooks/satellite/client-scripts.yaml -e "registration_hostgroup=hostgroup-for-{{ tests_registration_target }}"

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

section "Prepare env for openSCAP test"
ap openSCAP-sat-prep.log playbooks/tests/openSCAP-sat-prep.yaml -e "proxy_id=$proxy_id hostgroup_name={{ tests_registration_target }}"

section "Register more and more"
ansible_container_hosts=$( ansible -i $inventory --list-hosts container_hosts,container_hosts 2>/dev/null | grep '^  hosts' | sed 's/^  hosts (\([0-9]\+\)):$/\1/' )
sum=0
for b in $registrations_batches; do
    let sum+=$( expr $b \* $ansible_container_hosts )
done
log "Going to register $sum hosts in total. Make sure there is enough hosts available."

export skip_measurement='false'

sum=0
totalclients=0
iter=1
for batch in $registrations_batches; do
    ap regs-50-register-$iter-$batch.log playbooks/tests/registrations.yaml -e "size=$batch registration_logs='../../$logs/regs-50-register-container-host-client-logs' method=clients-bootstrap.yaml registration_hostgroup=hostgroup-for-{{ tests_registration_target }}"
    e Register $logs/regs-50-register-$iter-$batch.log
    s $wait_interval
    let sum=$(($sum + $batch))
    let totalclients=$( expr $sum \* $ansible_container_hosts )
    ap openSCAP-host-$iter-$totalclients.log playbooks/tests/openSCAP-host-prep.yaml
    ap openSCAP-role-$iter-$totalclients.log playbooks/tests/openSCAP-role.yaml -e "max_age_task=$max_age_input"
    s $wait_interval
    ap openSCAP-test-$iter-$totalclients.log playbooks/tests/openSCAP-test.yaml -e "max_age_task=$max_age_input"
    log "$(curl --insecure $workdir_url/$job_name/$logs/openSCAP-test-$iter-$totalclients.log | grep -i 'result:')"
    let iter+=1
    s $wait_interval
done

section "Summary"
iter=1
sum=0
totalclients=0
for batch in $registrations_batches; do
    let sum=$(($sum + $batch))
    let totalclients=$( expr $sum \* $ansible_container_hosts )
    log "$(curl --insecure $workdir_url/$job_name/$logs/openSCAP-test-$iter-$totalclients.log | grep -i 'result:')"
    log "$(grep 'RESULT:' $logs/openSCAP-test-$iter-$totalclients.log)"
    let iter+=1
done

ap sosreporter-gatherer.log playbooks/satellite/sosreport_gatherer.yaml -e "sosreport_gatherer_local_dir=$logs"

junit_upload

