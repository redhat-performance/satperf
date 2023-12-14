#!/bin/bash

source experiment/run-library.sh

branch="${PARAM_branch:-satcpt}"
inventory="${PARAM_inventory:-conf/contperf/inventory.${branch}.ini}"
manifest="${PARAM_manifest:-conf/contperf/manifest_SCA.zip}"

registrations_per_docker_hosts=${PARAM_registrations_per_docker_hosts:-5}
registrations_iterations=${PARAM_registrations_iterations:-20}

puppet_one_concurency="${PARAM_puppet_one_concurency:-5 15 30}"
puppet_bunch_concurency="${PARAM_puppet_bunch_concurency:-2 6 10 14 18}"

cdn_url_mirror="${PARAM_cdn_url_mirror:-https://cdn.redhat.com/}"
cdn_url_full="${PARAM_cdn_url_full:-https://cdn.redhat.com/}"

repo_sat_client_7="${PARAM_repo_sat_client_7:-http://mirror.example.com/Satellite_Client_7_x86_64/}"
repo_sat_client_8="${PARAM_repo_sat_client_8:-http://mirror.example.com/Satellite_Client_8_x86_64/}"

ui_pages_reloads="${PARAM_ui_pages_reloads:-10}"

dl="Default Location"

opts="--forks 100 -i $inventory"
opts_adhoc="$opts"


section "Checking environment"
generic_environment_check false


###section "Prepare for Red Hat content"
###a 00-manifest-deploy.log -m copy -a "src=$manifest dest=/root/manifest-auto.zip force=yes" satellite6
###count=5
###for i in $( seq $count ); do
###    h 01-manifest-upload-$i.log "subscription upload --file '/root/manifest-auto.zip' --organization '{{ sat_org }}'"
###    if [ $i -lt $count ]; then
###        h 02-manifest-delete-$i.log "subscription delete-manifest --organization '{{ sat_org }}'"
###    fi
###done
###
###
###section "Sync from mirror"
###h 00-set-local-cdn-mirror.log "organization update --name '{{ sat_org }}' --redhat-repository-url '$cdn_url_mirror'"
###h 10-reposet-enable-rhel7.log  "repository-set enable --organization '{{ sat_org }}' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server (RPMs)' --releasever '7Server' --basearch 'x86_64'"
###h 10-reposet-enable-rhel6.log  "repository-set enable --organization '{{ sat_org }}' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 6 Server (RPMs)' --releasever '6Server' --basearch 'x86_64'"
###h 10-reposet-enable-rhel7optional.log "repository-set enable --organization '{{ sat_org }}' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server - Optional (RPMs)' --releasever '7Server' --basearch 'x86_64'"
###h 11-repo-immediate-rhel7.log "repository update --organization '{{ sat_org }}' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server' --download-policy 'immediate'"
###h 12-repo-sync-rhel7.log "repository synchronize --organization '{{ sat_org }}' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server'"
###h 12-repo-sync-rhel6.log "repository synchronize --organization '{{ sat_org }}' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 6 Server RPMs x86_64 6Server'"
###h 12-repo-sync-rhel7optional.log "repository synchronize --organization '{{ sat_org }}' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server - Optional RPMs x86_64 7Server'"
###
###section "Synchronise capsules"
###tmp=$( mktemp )
###h_out "--no-headers --csv capsule list --organization '{{ sat_org }}'" | grep '^[0-9]\+,' >$tmp
###for capsule_id in $( cat $tmp | cut -d ',' -f 1 | grep -v -e '1' ); do
###    skip_measurement='true' h 13-capsule-add-library-lce-$capsule_id.log "capsule content add-lifecycle-environment  --organization '{{ sat_org }}' --id '$capsule_id' --lifecycle-environment 'Library'"
###    h 13-capsule-sync-$capsule_id.log "capsule content synchronize --organization '{{ sat_org }}' --id '$capsule_id'"
###done
###
###section "Publish and promote big CV"
###rids="$rids,$( get_repo_id '{{ sat_org }}' 'Red Hat Enterprise Linux Server' 'Red Hat Enterprise Linux 6 Server RPMs x86_64 6Server' )"
###rids="$rids,$( get_repo_id '{{ sat_org }}' 'Red Hat Enterprise Linux Server' 'Red Hat Enterprise Linux 7 Server - Optional RPMs x86_64 7Server' )"
###h 20-cv-create-all.log "content-view create --organization '{{ sat_org }}' --repository-ids '$rids' --name 'BenchContentView'"
###h 21-cv-all-publish.log "content-view publish --organization '{{ sat_org }}' --name 'BenchContentView'"
###h 22-le-create-1.log "lifecycle-environment create --organization '{{ sat_org }}' --prior 'Library' --name 'BenchLifeEnvAAA'"
###h 22-le-create-2.log "lifecycle-environment create --organization '{{ sat_org }}' --prior 'BenchLifeEnvAAA' --name 'BenchLifeEnvBBB'"
###h 22-le-create-3.log "lifecycle-environment create --organization '{{ sat_org }}' --prior 'BenchLifeEnvBBB' --name 'BenchLifeEnvCCC'"
###h 23-cv-all-promote-1.log "content-view version promote --organization '{{ sat_org }}' --content-view 'BenchContentView' --to-lifecycle-environment 'Library' --to-lifecycle-environment 'BenchLifeEnvAAA'"
###h 23-cv-all-promote-2.log "content-view version promote --organization '{{ sat_org }}' --content-view 'BenchContentView' --to-lifecycle-environment 'BenchLifeEnvAAA' --to-lifecycle-environment 'BenchLifeEnvBBB'"
###h 23-cv-all-promote-3.log "content-view version promote --organization '{{ sat_org }}' --content-view 'BenchContentView' --to-lifecycle-environment 'BenchLifeEnvBBB' --to-lifecycle-environment 'BenchLifeEnvCCC'"
###
###
###section "Publish and promote filtered CV"
###rids="$( get_repo_id '{{ sat_org }}' 'Red Hat Enterprise Linux Server' 'Red Hat Enterprise Linux 6 Server RPMs x86_64 6Server' )"
###h 30-cv-create-filtered.log "content-view create --organization '{{ sat_org }}' --repository-ids '$rids' --name 'BenchFilteredContentView'"
###h 31-filter-create-1.log "content-view filter create --organization '{{ sat_org }}' --type erratum --inclusion true --content-view BenchFilteredContentView --name BenchFilterAAA"
###h 31-filter-create-2.log "content-view filter create --organization '{{ sat_org }}' --type erratum --inclusion true --content-view BenchFilteredContentView --name BenchFilterBBB"
###h 32-rule-create-1.log "content-view filter rule create --content-view BenchFilteredContentView --content-view-filter BenchFilterAAA --date-type 'issued' --start-date 2016-01-01 --end-date 2017-10-01 --organization '{{ sat_org }}' --types enhancement,bugfix,security"
###h 32-rule-create-2.log "content-view filter rule create --content-view BenchFilteredContentView --content-view-filter BenchFilterBBB --date-type 'updated' --start-date 2016-01-01 --end-date 2018-01-01 --organization '{{ sat_org }}' --types security"
###h 33-cv-filtered-publish.log "content-view publish --organization '{{ sat_org }}' --name 'BenchFilteredContentView'"
###
###
###section "Sync from CDN do not measure"   # do not measure because of unpredictable network latency
###h 00b-set-cdn-stage.log "organization update --name '{{ sat_org }}' --redhat-repository-url '$cdn_url_full'"
###h 03b-manifest-refresh.log "subscription refresh-manifest --organization '{{ sat_org }}'"
###h 10b-reposet-enable-rhel7.log  "repository-set enable --organization '{{ sat_org }}' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server (RPMs)' --releasever '7Server' --basearch 'x86_64'"
###h 10b-reposet-enable-rhel6.log  "repository-set enable --organization '{{ sat_org }}' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 6 Server (RPMs)' --releasever '6Server' --basearch 'x86_64'"
###h 10b-reposet-enable-rhel7optional.log "repository-set enable --organization '{{ sat_org }}' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server - Optional (RPMs)' --releasever '7Server' --basearch 'x86_64'"
###h 12b-repo-sync-rhel7.log "repository synchronize --organization '{{ sat_org }}' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server'" &
###h 12b-repo-sync-rhel6.log "repository synchronize --organization '{{ sat_org }}' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 6 Server RPMs x86_64 6Server'" &
###h 12b-repo-sync-rhel7optional.log "repository synchronize --organization '{{ sat_org }}' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server - Optional RPMs x86_64 7Server'" &
###wait
###
###section "Sync Client repos"
###h regs-30-sat-client-product-create.log "product create --organization '{{ sat_org }}' --name SatClientProduct"
###h regs-30-repository-create-sat-client_7.log "repository create --organization '{{ sat_org }}' --product SatClientProduct --name SatClient7Repo --content-type yum --url '$repo_sat_client_7'"
###h regs-30-repository-sync-sat-client_7.log "repository synchronize --organization '{{ sat_org }}' --product SatClientProduct --name SatClient7Repo"
###h regs-30-repository-create-sat-client_8.log "repository create --organization '{{ sat_org }}' --product SatClientProduct --name SatClient8Repo --content-type yum --url '$repo_sat_client_8'"
###h regs-30-repository-sync-sat-client_8.log "repository synchronize --organization '{{ sat_org }}' --product SatClientProduct --name SatClient8Repo"
###
###
###section "Synchronise capsules again do not measure"   # We just added up2date content from CDN, so no reason to measure this now
###tmp=$( mktemp )
###h_out "--no-headers --csv capsule list --organization '{{ sat_org }}'" | grep '^[0-9]\+,' >$tmp
###for capsule_id in $( cat $tmp | cut -d ',' -f 1 | grep -v '1' ); do
###    h 13b-capsule-sync-$capsule_id.log "capsule content synchronize --organization '{{ sat_org }}' --id '$capsule_id'"
###done


section "Prepare for registrations"
h_out "--no-headers --csv domain list --search 'name = {{ domain }}'" | grep --quiet '^[0-9]\+,' \
    || h 42-domain-create.log "domain create --name '{{ domain }}' --organizations '{{ sat_org }}'"
tmp=$( mktemp )
h_out "--no-headers --csv location list --organization '{{ sat_org }}'" | grep '^[0-9]\+,' >$tmp
location_ids=$( cut -d ',' -f 1 $tmp | tr '\n' ',' | sed 's/,$//' )
h 42-domain-update.log "domain update --name '{{ domain }}' --organizations '{{ sat_org }}' --location-ids '$location_ids'"

h 43-ak-create.log "activation-key create --content-view '{{ sat_org }} View' --lifecycle-environment Library --name ActivationKey --organization '{{ sat_org }}'"
h 43-subs-list-client.log "--csv subscription list --organization '{{ sat_org }}' --search 'name = SatClientProduct'"
client_subs_id=$( tail -n 1 $logs/subs-list-client.log | cut -d ',' -f 1 )
h 43-ak-add-subs-client.log "activation-key add-subscription --organization '{{ sat_org }}' --name ActivationKey --subscription-id '$client_subs_id'"
h 43-subs-list-employee.log "--csv subscription list --organization '{{ sat_org }}' --search 'name = \"Employee SKU\"'"
employee_subs_id=$( tail -n 1 $logs/subs-list-employee.log | cut -d ',' -f 1 )
h 43-ak-add-subs-employee.log "activation-key add-subscription --organization '{{ sat_org }}' --name ActivationKey --subscription-id '$employee_subs_id'"

ap 44-generate-host-registration-command.log \
  -e "organization='{{ sat_org }}'" \
  -e "ak=ActivationKey" \
  playbooks/satellite/host-registration_generate-command.yaml

ap 44-recreate-client-scripts.log \
  playbooks/satellite/client-scripts.yaml


section "Register"
for i in $( seq $registrations_iterations ); do
    ap 44-register-$i.log playbooks/tests/registrations.yaml -e "size=$registrations_per_docker_hosts tags=untagged,REG,REM bootstrap_activationkey='ActivationKey' bootstrap_hostgroup='hostgroup-for-{{ tests_registration_target }}' grepper='Register' registration_logs='../../$logs/44-register-docker-host-client-logs'"
    e Register $logs/44-register-$i.log
done


section "Remote execution"
h 50-rex-set-via-ip.log "settings set --name remote_execution_connect_by_ip --value true"
a 51-rex-cleanup-know_hosts.log satellite6 -m "shell" -a "rm -rf /usr/share/foreman-proxy/.ssh/known_hosts*"
h 52-rex-date.log "job-invocation create --description-format 'Run %{command} (%{template_name})' --inputs command='date' --job-template 'Run Command - SSH Default' --search-query 'name ~ container'"
h 52-rex-date-ansible.log "job-invocation create --description-format 'Run %{command} (%{template_name})' --inputs command='date' --job-template 'Run Command - Ansible Default' --search-query 'name ~ container'"
h 53-rex-sm-facts-update.log "job-invocation create --description-format 'Run %{command} (%{template_name})' --inputs command='subscription-manager facts --update' --job-template 'Run Command - SSH Default' --search-query 'name ~ container'"
h 54-rex-uploadprofile.log "job-invocation create --description-format 'Run %{command} (%{template_name})' --inputs command='dnf uploadprofile --force-upload' --job-template 'Run Command - SSH Default' --search-query 'name ~ container'"


section "Misc simple tests"
ap 60-generate-applicability.log playbooks/tests/generate-applicability.yaml
e GenerateApplicability $logs/60-generate-applicability.log
ap 61-hammer-list.log \
  -e "organization='{{ sat_org }}'" \
  playbooks/tests/hammer-list.yaml
e HammerHostList $logs/61-hammer-list.log
ap 62-some-webui-pages.log -e "ui_pages_reloads=$ui_pages_reloads" playbooks/tests/some-webui-pages.yaml
a 63-foreman_inventory_upload-report-generate.log satellite6 -m "shell" -a "export organization='{{ sat_org }}'; export target=/var/lib/foreman/red_hat_inventory/generated_reports/; /usr/sbin/foreman-rake foreman_inventory_upload:report:generate"


section "Preparing Puppet environment"
ap satellite-puppet-single-cv.log \
  -e "organization='{{ sat_org }}'" \
  playbooks/tests/puppet-single-setup.yaml &
ap satellite-puppet-big-cv.log \
  -e "organization='{{ sat_org }}'" \
  playbooks/tests/puppet-big-setup.yaml &
a clear-used-containers-counter.log -m shell -a "echo 0 >/root/container-used-count" docker_hosts &
wait


section "Apply one module with different concurency"
for concurency in $( echo "$puppet_one_concurency" | tr " " "\n" | sort -n -u ); do
    iterations=$( echo "$puppet_one_concurency" | tr " " "\n" | grep "^$concurency$" | wc -l | cut -d ' ' -f 1 )
    for iteration in $( seq $iterations ); do
        ap $concurency-PuppetOne-$iteration.log playbooks/tests/puppet-big-test.yaml --tags SINGLE -e "size=$concurency"
        e RegisterPuppet $logs/$concurency-PuppetOne-$iteration.log
        e SetupPuppet $logs/$concurency-PuppetOne-$iteration.log
        e PickupPuppet $logs/$concurency-PuppetOne-$iteration.log
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
    done
done


junit_upload
