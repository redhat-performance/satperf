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


section "Upload manifest"
h regs-10-ensure-loc-in-org.log "organization add-location --name 'Default Organization' --location 'Default Location'"
h regs-10-manifest-upload.log "subscription upload --file '/root/manifest-auto.zip' --organization '$do'"
s $wait_interval


section "Sync from CDN"   # do not measure because of unpredictable network latency
h regs-20-set-cdn-stage.log "organization update --name 'Default Organization' --redhat-repository-url '$cdn_url_full'"
h regs-20-reposet-enable-rhel7.log  "repository-set enable --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server (RPMs)' --releasever '7Server' --basearch 'x86_64'"
h regs-20-repo-immediate-rhel7.log "repository update --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server' --download-policy 'immediate'"#h regs-20-repo-sync-rhel7.log "repository synchronize --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server'"
s $wait_interval


section "Sync Tools repo"   # do not measure because of unpredictable network latency
h regs-30-sat-tools-product-create.log "product create --organization '$do' --name SatToolsProduct"
h regs-30-repository-create-sat-tools.log "repository create --organization '$do' --product SatToolsProduct --name SatToolsRepo --content-type yum --url '$repo_sat_tools'"
h regs-30-repository-sync-sat-tools.log "repository synchronize --organization '$do' --product SatToolsProduct --name SatToolsRepo"
s $wait_interval


section "Prepare for registrations"
ap regs-40-recreate-client-scripts.log playbooks/satellite/client-scripts.yaml   # this detects OS, so need to run after we synces one
h regs-40-hostgroup-create.log "hostgroup create --content-view 'Default Organization View' --lifecycle-environment Library --name HostGroup1 --query-organization '$do'"
h regs-40-domain-create.log "domain create --name {{ client_domain }} --organizations '$do'"
h regs-40-domain-update.log "domain update --name {{ client_domain }} --organizations '$do' --locations '$dl'"
h regs-40-ak-create.log "activation-key create --content-view 'Default Organization View' --lifecycle-environment Library --name ActivationKey1 --organization '$do'"
h regs-40-subs-list-tools.log "--csv subscription list --organization '$do' --search 'name = SatToolsProduct'"
tools_subs_id=$( tail -n 1 $logs/regs-40-subs-list-tools.log | cut -d ',' -f 1 )
h regs-40-ak-add-subs-tools.log "activation-key add-subscription --organization '$do' --name ActivationKey1 --subscription-id '$tools_subs_id'"
h regs-40-subs-list-employee.log "--csv subscription list --organization '$do' --search 'name = \"Employee SKU\"'"
employee_subs_id=$( tail -n 1 $logs/regs-40-subs-list-employee.log | cut -d ',' -f 1 )
h regs-40-ak-add-subs-employee.log "activation-key add-subscription --organization '$do' --name ActivationKey1 --subscription-id '$employee_subs_id'"


section "Register more and more"
ansible_docker_hosts=$( ansible -i $inventory --list-hosts docker-hosts 2>/dev/null | grep '^  hosts' | sed 's/^  hosts (\([0-9]\+\)):$/\1/' )
sum=0
for b in $registrations_batches; do
    let sum+=$( expr $b \* $ansible_docker_hosts )
done
log "Going to register $sum hosts in total. Make sure there is enough hosts available."

iter=1
for batch in $registrations_batches; do
    ap regs-50-register-$iter-$batch.log playbooks/tests/registrations.yaml -e "size=$batch tags=untagged,REG,REM bootstrap_activationkey='ActivationKey1' bootstrap_hostgroup='HostGroup1' grepper='Register' bootstrap_retries=0 bootstrap_additional_args='$bootstrap_additional_args'"
    e Register $logs/regs-50-register-$iter-$batch.log
    let iter+=1
    s $wait_interval
done

section "Summary"
iter=1
for batch in $registrations_batches; do
    log "$( experiment/reg-average.sh Register $logs/regs-50-register-$iter-$batch.log | tail -n 1 )"
    let iter+=1
done

junit_upload
