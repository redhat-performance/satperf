#!/bin/bash

source experiment/run-library.sh

manifest="${PARAM_manifest:-conf/contperf/manifest.zip}"
inventory="${PARAM_inventory:-conf/contperf/inventory.ini}"
private_key="${PARAM_private_key:-conf/contperf/id_rsa_perf}"

registrations_per_docker_hosts=${PARAM_registrations_per_docker_hosts:-5}
registrations_iterations=${PARAM_registrations_iterations:-20}
wait_interval=${PARAM_wait_interval:-50}

puppet_one_concurency="${PARAM_puppet_one_concurency:-5 15 30}"
puppet_bunch_concurency="${PARAM_puppet_bunch_concurency:-2 6 10 14 18}"

cdn_url_mirror="${PARAM_cdn_url_mirror:-https://cdn.redhat.com/}"
cdn_url_full="${PARAM_cdn_url_full:-https://cdn.redhat.com/}"

repo_sat_tools="${PARAM_repo_sat_tools:-http://mirror.example.com/Satellite_Tools_x86_64/}"
repo_sat_tools_puppet="${PARAM_repo_sat_tools_puppet:-none}"   # Older example: http://mirror.example.com/Satellite_Tools_Puppet_4_6_3_RHEL7_x86_64/

repo_sat_client_7="${PARAM_repo_sat_client_7:-http://mirror.example.com/Satellite_Client_7_x86_64/}"
repo_sat_client_8="${PARAM_repo_sat_client_8:-http://mirror.example.com/Satellite_Client_8_x86_64/}"

ui_pages_reloads="${PARAM_ui_pages_reloads:-10}"

do="Default Organization"
dl="Default Location"

opts="-i $inventory --private-key $private_key"
opts_adhoc="$opts --user root -e @conf/satperf.yaml -e @conf/satperf.local.yaml"


section "Checking environment"
generic_environment_check false


###section "Prepare for Red Hat content"
###h 00-ensure-loc-in-org.log "organization add-location --name 'Default Organization' --location 'Default Location'"
###a 00-manifest-deploy.log -m copy -a "src=$manifest dest=/root/manifest-auto.zip force=yes" satellite6
###count=5
###for i in $( seq $count ); do
###    h 01-manifest-upload-$i.log "subscription upload --file '/root/manifest-auto.zip' --organization '$do'"
###    s $wait_interval
###    if [ $i -lt $count ]; then
###        h 02-manifest-delete-$i.log "subscription delete-manifest --organization '$do'"
###        s $wait_interval
###    fi
###done
###h 03-manifest-refresh.log "subscription refresh-manifest --organization '$do'"
###s $wait_interval
###
###
###section "Sync from mirror"
###h 00-set-local-cdn-mirror.log "organization update --name 'Default Organization' --redhat-repository-url '$cdn_url_mirror'"
###h 10-reposet-enable-rhel7.log  "repository-set enable --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server (RPMs)' --releasever '7Server' --basearch 'x86_64'"
###h 10-reposet-enable-rhel6.log  "repository-set enable --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 6 Server (RPMs)' --releasever '6Server' --basearch 'x86_64'"
###h 10-reposet-enable-rhel7optional.log "repository-set enable --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server - Optional (RPMs)' --releasever '7Server' --basearch 'x86_64'"
###h 11-repo-immediate-rhel7.log "repository update --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server' --download-policy 'immediate'"
###h 12-repo-sync-rhel7.log "repository synchronize --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server'"
###s $wait_interval
###h 12-repo-sync-rhel6.log "repository synchronize --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 6 Server RPMs x86_64 6Server'"
###s $wait_interval
###h 12-repo-sync-rhel7optional.log "repository synchronize --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server - Optional RPMs x86_64 7Server'"
###s $wait_interval
###
###section "Synchronise capsules"
###tmp=$( mktemp )
###h_out "--no-headers --csv capsule list --organization '$do'" | grep '^[0-9]\+,' >$tmp
###for capsule_id in $( cat $tmp | cut -d ',' -f 1 | grep -v -e '1' ); do
###    h 13-capsule-sync-$capsule_id.log "capsule content synchronize --organization '$do' --id '$capsule_id'"
###done
###s $wait_interval
###
###section "Publish and promote big CV"
###rids="$( get_repo_id 'Red Hat Enterprise Linux Server' 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server' )"
###rids="$rids,$( get_repo_id 'Red Hat Enterprise Linux Server' 'Red Hat Enterprise Linux 6 Server RPMs x86_64 6Server' )"
###rids="$rids,$( get_repo_id 'Red Hat Enterprise Linux Server' 'Red Hat Enterprise Linux 7 Server - Optional RPMs x86_64 7Server' )"
###h 20-cv-create-all.log "content-view create --organization '$do' --repository-ids '$rids' --name 'BenchContentView'"
###h 21-cv-all-publish.log "content-view publish --organization '$do' --name 'BenchContentView'"
###s $wait_interval
###h 22-le-create-1.log "lifecycle-environment create --organization '$do' --prior 'Library' --name 'BenchLifeEnvAAA'"
###h 22-le-create-2.log "lifecycle-environment create --organization '$do' --prior 'BenchLifeEnvAAA' --name 'BenchLifeEnvBBB'"
###h 22-le-create-3.log "lifecycle-environment create --organization '$do' --prior 'BenchLifeEnvBBB' --name 'BenchLifeEnvCCC'"
###h 23-cv-all-promote-1.log "content-view version promote --organization 'Default Organization' --content-view 'BenchContentView' --to-lifecycle-environment 'Library' --to-lifecycle-environment 'BenchLifeEnvAAA'"
###s $wait_interval
###h 23-cv-all-promote-2.log "content-view version promote --organization 'Default Organization' --content-view 'BenchContentView' --to-lifecycle-environment 'BenchLifeEnvAAA' --to-lifecycle-environment 'BenchLifeEnvBBB'"
###s $wait_interval
###h 23-cv-all-promote-3.log "content-view version promote --organization 'Default Organization' --content-view 'BenchContentView' --to-lifecycle-environment 'BenchLifeEnvBBB' --to-lifecycle-environment 'BenchLifeEnvCCC'"
###s $wait_interval
###
###
###section "Publish and promote filtered CV"
###rids="$( get_repo_id 'Red Hat Enterprise Linux Server' 'Red Hat Enterprise Linux 6 Server RPMs x86_64 6Server' )"
###h 30-cv-create-filtered.log "content-view create --organization '$do' --repository-ids '$rids' --name 'BenchFilteredContentView'"
###h 31-filter-create-1.log "content-view filter create --organization '$do' --type erratum --inclusion true --content-view BenchFilteredContentView --name BenchFilterAAA"
###h 31-filter-create-2.log "content-view filter create --organization '$do' --type erratum --inclusion true --content-view BenchFilteredContentView --name BenchFilterBBB"
###h 32-rule-create-1.log "content-view filter rule create --content-view BenchFilteredContentView --content-view-filter BenchFilterAAA --date-type 'issued' --start-date 2016-01-01 --end-date 2017-10-01 --organization '$do' --types enhancement,bugfix,security"
###h 32-rule-create-2.log "content-view filter rule create --content-view BenchFilteredContentView --content-view-filter BenchFilterBBB --date-type 'updated' --start-date 2016-01-01 --end-date 2018-01-01 --organization '$do' --types security"
###h 33-cv-filtered-publish.log "content-view publish --organization '$do' --name 'BenchFilteredContentView'"
###s $wait_interval
###
###
###section "Sync from CDN do not measure"   # do not measure becasue of unpredictable network latency
###h 00b-set-cdn-stage.log "organization update --name 'Default Organization' --redhat-repository-url '$cdn_url_full'"
###h 10b-reposet-enable-rhel7.log  "repository-set enable --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server (RPMs)' --releasever '7Server' --basearch 'x86_64'"
###h 10b-reposet-enable-rhel6.log  "repository-set enable --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 6 Server (RPMs)' --releasever '6Server' --basearch 'x86_64'"
###h 10b-reposet-enable-rhel7optional.log "repository-set enable --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server - Optional (RPMs)' --releasever '7Server' --basearch 'x86_64'"
###h 12b-repo-sync-rhel7.log "repository synchronize --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server'" &
###h 12b-repo-sync-rhel6.log "repository synchronize --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 6 Server RPMs x86_64 6Server'" &
###h 12b-repo-sync-rhel7optional.log "repository synchronize --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server - Optional RPMs x86_64 7Server'" &
###wait
###s $wait_interval
###
###
###section "Sync Tools repo"
###h product-create.log "product create --organization '$do' --name SatToolsProduct"
###h repository-create-sat-tools.log "repository create --organization '$do' --product SatToolsProduct --name SatToolsRepo --content-type yum --url '$repo_sat_tools'"
###[ "$repo_sat_tools_puppet" != "none" ] \
###    && h repository-create-puppet-upgrade.log "repository create --organization '$do' --product SatToolsProduct --name SatToolsPuppetRepo --content-type yum --url '$repo_sat_tools_puppet'"
###h repository-sync-sat-tools.log "repository synchronize --organization '$do' --product SatToolsProduct --name SatToolsRepo" &
###[ "$repo_sat_tools_puppet" != "none" ] \
###    && h repository-sync-puppet-upgrade.log "repository synchronize --organization '$do' --product SatToolsProduct --name SatToolsPuppetRepo" &
###wait
###s $wait_interval
###
###section "Sync Client repos"
###h regs-30-sat-client-product-create.log "product create --organization '$do' --name SatClientProduct"
###h regs-30-repository-create-sat-client_7.log "repository create --organization '$do' --product SatClientProduct --name SatClient7Repo --content-type yum --url '$repo_sat_client_7'"
###h regs-30-repository-sync-sat-client_7.log "repository synchronize --organization '$do' --product SatClientProduct --name SatClient7Repo"
###s $wait_interval
###h regs-30-repository-create-sat-client_8.log "repository create --organization '$do' --product SatClientProduct --name SatClient8Repo --content-type yum --url '$repo_sat_client_8'"
###h regs-30-repository-sync-sat-client_8.log "repository synchronize --organization '$do' --product SatClientProduct --name SatClient8Repo"
###s $wait_interval
###
###
###section "Synchronise capsules again do not measure"   # We just added up2date content from CDN and SatToolsRepo, so no reason to measure this now
###tmp=$( mktemp )
###h_out "--no-headers --csv capsule list --organization '$do'" | grep '^[0-9]\+,' >$tmp
###for capsule_id in $( cat $tmp | cut -d ',' -f 1 | grep -v '1' ); do
###    h 13b-capsule-sync-$capsule_id.log "capsule content synchronize --organization '$do' --id '$capsule_id'"
###done
###s $wait_interval


section "Prepare for registrations"
ap 40-recreate-client-scripts.log playbooks/satellite/client-scripts.yaml   # this detects OS, so need to run after we synces one
h_out "--no-headers --csv domain list --search 'name = {{ containers_domain }}'" | grep --quiet '^[0-9]\+,' \
    || h 42-domain-create.log "domain create --name '{{ containers_domain }}' --organizations '$do'"
tmp=$( mktemp )
h_out "--no-headers --csv location list --organization '$do'" | grep '^[0-9]\+,' >$tmp
location_ids=$( cut -d ',' -f 1 $tmp | tr '\n' ',' | sed 's/,$//' )
h 42-domain-update.log "domain update --name '{{ containers_domain }}' --organizations '$do' --location-ids '$location_ids'"
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
        || h 44-subnet-create-$capsule_name.log "subnet create --name '$subnet_name' --ipam None --domains '{{ containers_domain }}' --organization '$do' --network 172.31.0.0 --mask 255.255.0.0 --location '$location_name'"
    subnet_id=$( h_out "--output yaml subnet info --name '$subnet_name'" | grep '^Id:' | cut -d ' ' -f 2 )
    a 45-subnet-add-rex-capsule-$capsule_name.log satellite6 -m "shell" -a "curl --silent --insecure -u {{ sat_user }}:{{ sat_pass }} -X PUT -H 'Accept: application/json' -H 'Content-Type: application/json' https://localhost//api/v2/subnets/$subnet_id -d '{\"subnet\": {\"remote_execution_proxy_ids\": [\"$capsule_id\"]}}'"
    h_out "--no-headers --csv hostgroup list --search 'name = $hostgroup_name'" | grep --quiet '^[0-9]\+,' \
        || h 41-hostgroup-create-$capsule_name.log "hostgroup create --content-view 'Default Organization View' --lifecycle-environment Library --name '$hostgroup_name' --query-organization '$do' --subnet '$subnet_name'"
done
h 43-ak-create.log "activation-key create --content-view 'Default Organization View' --lifecycle-environment Library --name ActivationKey --organization '$do'"
h 43-subs-list-tools.log "--csv subscription list --organization '$do' --search 'name = SatToolsProduct'"
tools_subs_id=$( tail -n 1 $logs/subs-list-tools.log | cut -d ',' -f 1 )
h 43-ak-add-subs-tools.log "activation-key add-subscription --organization '$do' --name ActivationKey --subscription-id '$tools_subs_id'"
h 43-subs-list-client.log "--csv subscription list --organization '$do' --search 'name = SatClientProduct'"
client_subs_id=$( tail -n 1 $logs/subs-list-client.log | cut -d ',' -f 1 )
h 43-ak-add-subs-client.log "activation-key add-subscription --organization '$do' --name ActivationKey --subscription-id '$client_subs_id'"
h 43-subs-list-employee.log "--csv subscription list --organization '$do' --search 'name = \"Employee SKU\"'"
employee_subs_id=$( tail -n 1 $logs/subs-list-employee.log | cut -d ',' -f 1 )
h 43-ak-add-subs-employee.log "activation-key add-subscription --organization '$do' --name ActivationKey --subscription-id '$employee_subs_id'"


section "Register"
for i in $( seq $registrations_iterations ); do
    ap 44-register-$i.log playbooks/tests/registrations.yaml -e "size=$registrations_per_docker_hosts tags=untagged,REG,REM bootstrap_activationkey='ActivationKey' bootstrap_hostgroup='hostgroup-for-{{ tests_registration_target }}' grepper='Register' registration_logs='../../$logs/44-register-docker-host-client-logs'"
    e Register $logs/44-register-$i.log
    s $wait_interval
done


section "Remote execution"
h 50-rex-set-via-ip.log "settings set --name remote_execution_connect_by_ip --value true"
a 51-rex-cleanup-know_hosts.log satellite6 -m "shell" -a "rm -rf /usr/share/foreman-proxy/.ssh/known_hosts*"
h 52-rex-date.log "job-invocation create --inputs command='date' --job-template 'Run Command - SSH Default' --search-query 'name ~ container'"
s $wait_interval
h 52-rex-date-ansible.log "job-invocation create --inputs command='date' --job-template 'Run Command - Ansible Default' --search-query 'name ~ container'"
s $wait_interval
h 53-rex-sm-facts-update.log "job-invocation create --inputs command='subscription-manager facts --update' --job-template 'Run Command - SSH Default' --search-query 'name ~ container'"
s $wait_interval
h 54-rex-uploadprofile.log "job-invocation create --inputs command='dnf uploadprofile --force-upload' --job-template 'Run Command - SSH Default' --search-query 'name ~ container'"
s $wait_interval


section "Misc simple tests"
ap 60-generate-applicability.log playbooks/tests/generate-applicability.yaml
e GenerateApplicability $logs/60-generate-applicability.log
s $wait_interval
ap 61-hammer-list.log playbooks/tests/hammer-list.yaml
e HammerHostList $logs/61-hammer-list.log
s $wait_interval
ap 62-some-webui-pages.log -e "ui_pages_reloads=$ui_pages_reloads" playbooks/tests/some-webui-pages.yaml
s $wait_interval
a 63-foreman_inventory_upload-report-generate.log satellite6 -m "shell" -a "export organization_id={{ sat_orgid }}; export target=/var/lib/foreman/red_hat_inventory/generated_reports/; /usr/sbin/foreman-rake foreman_inventory_upload:report:generate"
s $wait_interval


section "Preparing Puppet environment"
ap satellite-puppet-single-cv.log playbooks/tests/puppet-single-setup.yaml &
ap satellite-puppet-big-cv.log playbooks/tests/puppet-big-setup.yaml &
a clear-used-containers-counter.log -m shell -a "echo 0 >/root/container-used-count" docker_hosts &
wait
s $wait_interval


section "Apply one module with different concurency"
for concurency in $( echo "$puppet_one_concurency" | tr " " "\n" | sort -n -u ); do
    iterations=$( echo "$puppet_one_concurency" | tr " " "\n" | grep "^$concurency$" | wc -l | cut -d ' ' -f 1 )
    for iteration in $( seq $iterations ); do
        ap $concurency-PuppetOne-$iteration.log playbooks/tests/puppet-big-test.yaml --tags SINGLE -e "size=$concurency"
        e RegisterPuppet $logs/$concurency-PuppetOne-$iteration.log
        e SetupPuppet $logs/$concurency-PuppetOne-$iteration.log
        e PickupPuppet $logs/$concurency-PuppetOne-$iteration.log
        s $wait_interval
    done
done


section "Apply bunch of modules with different concurency"
for concurency in $( echo "$puppet_bunch_concurency" | tr " " "\n" | sort -n -u ); do
    iterations=$( echo "$puppet_bunch_concurency" | tr " " "\n" | grep "^$concurency$" | wc -l | cut -d ' ' -f 1 )
    for iteration in $( seq $iterations ); do
        ap $concurency-PuppetBunch-$iteration.log playbooks/tests/puppet-big-test.yaml --tags BUNCH -e "size=$concurency"
        e RegisterPuppet $logs/$concurency-PuppetBunch-$iteration.log 
        e SetupPuppet $logs/$concurency-PuppetBunch-$iteration.log 
        e PickupPuppet $logs/$concurency-PuppetBunch-$iteration.log
        s $wait_interval
    done
done


junit_upload
