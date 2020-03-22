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

ui_pages_reloads="${PARAM_ui_pages_reloads:-10}"

do="Default Organization"
dl="Default Location"

opts="--forks 100 -i $inventory --private-key $private_key"
opts_adhoc="$opts --user root -e @conf/satperf.yaml -e @conf/satperf.local.yaml"


section "Checking environment"
a 00-info-rpm-qa.log satellite6 -m "shell" -a "rpm -qa | sort"
a 00-info-hostname.log satellite6 -m "shell" -a "hostname"
a 00-check-ping-sat.log docker-hosts -m "shell" -a "ping -c 3 {{ groups['satellite6']|first }}"
a 00-check-hammer-ping.log satellite6 -m "shell" -a "! ( hammer $hammer_opts ping | grep 'Status:' | grep -v 'ok$' )"
ap 00-recreate-containers.log playbooks/docker/docker-tierdown.yaml playbooks/docker/docker-tierup.yaml
ap 00-recreate-client-scripts.log playbooks/satellite/client-scripts.yaml
ap 00-remove-hosts-if-any.log playbooks/satellite/satellite-remove-hosts.yaml
a 00-satellite-drop-caches.log -m shell -a "katello-service stop; sync; echo 3 > /proc/sys/vm/drop_caches; katello-service start" satellite6
a 00-info-rpm-q-katello.log satellite6 -m "shell" -a "rpm -q katello"
katello_version=$( tail -n 1 $logs/00-info-rpm-q-katello.log ); echo "$katello_version" | grep '^katello-[0-9]\.'   # make sure it was detected correctly
a 00-info-rpm-q-satellite.log satellite6 -m "shell" -a "rpm -q satellite || true"
satellite_version=$( tail -n 1 $logs/00-info-rpm-q-satellite.log )
s $( expr 3 \* $wait_interval )
set +e


section "Prepare for Red Hat content"
h 00-ensure-loc-in-org.log "organization add-location --name 'Default Organization' --location 'Default Location'"
a 00-manifest-deploy.log -m copy -a "src=$manifest dest=/root/manifest-auto.zip force=yes" satellite6
count=5
for i in $( seq $count ); do
    h 01-manifest-upload-$i.log "subscription upload --file '/root/manifest-auto.zip' --organization '$do'"
    s $wait_interval
    if [ $i -lt $count ]; then
        h 02-manifest-delete-$i.log "subscription delete-manifest --organization '$do'"
        s $wait_interval
    fi
done
h 03-manifest-refresh.log "subscription refresh-manifest --organization '$do'"
s $wait_interval


section "Sync from mirror"
h 00-set-local-cdn-mirror.log "organization update --name 'Default Organization' --redhat-repository-url '$cdn_url_mirror'"
h 10-reposet-enable-rhel7.log  "repository-set enable --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server (RPMs)' --releasever '7Server' --basearch 'x86_64'"
h 10-reposet-enable-rhel6.log  "repository-set enable --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 6 Server (RPMs)' --releasever '6Server' --basearch 'x86_64'"
h 10-reposet-enable-rhel7optional.log "repository-set enable --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server - Optional (RPMs)' --releasever '7Server' --basearch 'x86_64'"
h 11-repo-immediate-rhel7.log "repository update --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server' --download-policy 'immediate'"
h 12-repo-sync-rhel7.log "repository synchronize --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server'"
s $wait_interval
h 12-repo-sync-rhel6.log "repository synchronize --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 6 Server RPMs x86_64 6Server'"
s $wait_interval
h 12-repo-sync-rhel7optional.log "repository synchronize --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server - Optional RPMs x86_64 7Server'"
s $wait_interval

section "Synchronise capsules"
tmp=$( mktemp )
h_out "--no-headers --csv capsule list --organization '$do'" | grep '^[0-9]\+,' >$tmp
for capsule_id in $( echo $tmp | cut -d ',' -f 1 | grep -v '1' ); do
    h 13-capsule-sync-$capsule_id.log "capsule content synchronize --organization '$do' --id '$capsule_id'"
done
s $wait_interval

section "Publish and promote big CV"
# Workaround for https://bugzilla.redhat.com/show_bug.cgi?id=1782707
if vercmp_ge "$katello_version" "3.16.0" || vercmp_ge "$satellite_version" "6.6.0"; then
    rids=""
    for r in 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server' 'Red Hat Enterprise Linux 6 Server RPMs x86_64 6Server' 'Red Hat Enterprise Linux 7 Server - Optional RPMs x86_64 7Server'; do
        tmp=$( mktemp )
        h_out "--output yaml repository info --organization '$do' --product 'Red Hat Enterprise Linux Server' --name '$r'" >$tmp
        rid=$( grep '^ID:' $tmp | cut -d ' ' -f 2 )
        [ ${#rids} -eq 0 ] && rids="$rid" || rids="$rids,$rid"
    done
    h 20-cv-create-all.log "content-view create --organization '$do' --repository-ids '$rids' --name 'BenchContentView'"
else
    h 20-cv-create-all.log "content-view create --organization '$do' --product 'Red Hat Enterprise Linux Server' --repositories 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server','Red Hat Enterprise Linux 6 Server RPMs x86_64 6Server','Red Hat Enterprise Linux 7 Server - Optional RPMs x86_64 7Server' --name 'BenchContentView'"
fi
h 21-cv-all-publish.log "content-view publish --organization '$do' --name 'BenchContentView'"
s $wait_interval
h 22-le-create-1.log "lifecycle-environment create --organization '$do' --prior 'Library' --name 'BenchLifeEnvAAA'"
h 22-le-create-2.log "lifecycle-environment create --organization '$do' --prior 'BenchLifeEnvAAA' --name 'BenchLifeEnvBBB'"
h 22-le-create-3.log "lifecycle-environment create --organization '$do' --prior 'BenchLifeEnvBBB' --name 'BenchLifeEnvCCC'"
h 23-cv-all-promote-1.log "content-view version promote --organization 'Default Organization' --content-view 'BenchContentView' --to-lifecycle-environment 'Library' --to-lifecycle-environment 'BenchLifeEnvAAA'"
s $wait_interval
h 23-cv-all-promote-2.log "content-view version promote --organization 'Default Organization' --content-view 'BenchContentView' --to-lifecycle-environment 'BenchLifeEnvAAA' --to-lifecycle-environment 'BenchLifeEnvBBB'"
s $wait_interval
h 23-cv-all-promote-3.log "content-view version promote --organization 'Default Organization' --content-view 'BenchContentView' --to-lifecycle-environment 'BenchLifeEnvBBB' --to-lifecycle-environment 'BenchLifeEnvCCC'"
s $wait_interval


section "Publish and promote filtered CV"
# Workaround for https://bugzilla.redhat.com/show_bug.cgi?id=1782707
if vercmp_ge "$katello_version" "3.16.0" || vercmp_ge "$satellite_version" "6.6.0"; then
    tmp=$( mktemp )
    h_out "--output yaml repository info --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 6 Server RPMs x86_64 6Server'" >$tmp
    rid=$( grep '^ID:' $tmp | cut -d ' ' -f 2 )
    h 30-cv-create-filtered.log "content-view create --organization '$do' --repository-ids '$rid' --name 'BenchFilteredContentView'"
else
    h 30-cv-create-filtered.log "content-view create --organization '$do' --product 'Red Hat Enterprise Linux Server' --repositories 'Red Hat Enterprise Linux 6 Server RPMs x86_64 6Server' --name 'BenchFilteredContentView'"
fi
h 31-filter-create-1.log "content-view filter create --organization '$do' --type erratum --inclusion true --content-view BenchFilteredContentView --name BenchFilterAAA"
h 31-filter-create-2.log "content-view filter create --organization '$do' --type erratum --inclusion true --content-view BenchFilteredContentView --name BenchFilterBBB"
h 32-rule-create-1.log "content-view filter rule create --content-view BenchFilteredContentView --content-view-filter BenchFilterAAA --date-type 'issued' --start-date 2016-01-01 --end-date 2017-10-01 --organization '$do' --types enhancement,bugfix,security"
h 32-rule-create-2.log "content-view filter rule create --content-view BenchFilteredContentView --content-view-filter BenchFilterBBB --date-type 'updated' --start-date 2016-01-01 --end-date 2018-01-01 --organization '$do' --types security"
h 33-cv-filtered-publish.log "content-view publish --organization '$do' --name 'BenchFilteredContentView'"
s $wait_interval


section "Sync from CDN do not measure"   # do not measure becasue of unpredictable network latency
h 00b-set-cdn-stage.log "organization update --name 'Default Organization' --redhat-repository-url '$cdn_url_full'"
h 10b-reposet-enable-rhel7.log  "repository-set enable --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server (RPMs)' --releasever '7Server' --basearch 'x86_64'"
h 10b-reposet-enable-rhel6.log  "repository-set enable --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 6 Server (RPMs)' --releasever '6Server' --basearch 'x86_64'"
h 10b-reposet-enable-rhel7optional.log "repository-set enable --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server - Optional (RPMs)' --releasever '7Server' --basearch 'x86_64'"
h 12b-repo-sync-rhel7.log "repository synchronize --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server'" &
h 12b-repo-sync-rhel6.log "repository synchronize --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 6 Server RPMs x86_64 6Server'" &
h 12b-repo-sync-rhel7optional.log "repository synchronize --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server - Optional RPMs x86_64 7Server'" &
wait
s $wait_interval


section "Sync Tools repo"
h product-create.log "product create --organization '$do' --name SatToolsProduct"
h repository-create-sat-tools.log "repository create --organization '$do' --product SatToolsProduct --name SatToolsRepo --content-type yum --url '$repo_sat_tools'"
[ "$repo_sat_tools_puppet" != "none" ] \
    && h repository-create-puppet-upgrade.log "repository create --organization '$do' --product SatToolsProduct --name SatToolsPuppetRepo --content-type yum --url '$repo_sat_tools_puppet'"
h repository-sync-sat-tools.log "repository synchronize --organization '$do' --product SatToolsProduct --name SatToolsRepo" &
[ "$repo_sat_tools_puppet" != "none" ] \
    && h repository-sync-puppet-upgrade.log "repository synchronize --organization '$do' --product SatToolsProduct --name SatToolsPuppetRepo" &
wait
s $wait_interval


section "Synchronise capsules again do not measure"   # We just added up2date content from CDN and SatToolsRepo, so no reason to measure this now
tmp=$( mktemp )
h_out "--no-headers --csv capsule list --organization '$do'" | grep '^[0-9]\+,' >$tmp
for capsule_id in $( echo $tmp | cut -d ',' -f 1 | grep -v '1' ); do
    h 13b-capsule-sync-$capsule_id.log "capsule content synchronize --organization '$do' --id '$capsule_id'"
done
s $wait_interval


section "Prepare for registrations"
ap 40-recreate-client-scripts.log playbooks/satellite/client-scripts.yaml   # this detects OS, so need to run after we synces one
h 42-domain-create.log "domain create --name '{{ client_domain }}' --organizations '$do'"
location_ids=$( h_out "--no-headers --csv location list --organization '$do'" | cut -d ',' -f 1 | tr '\n' ',' | sed 's/,$//' )
h 42-domain-update.log "domain update --name '{{ client_domain }}' --organizations '$do' --location-ids '$location_ids'"
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
    h 44-subnet-create-$capsule_name.log "subnet create --name '$subnet_name' --ipam None --domains '{{ client_domain }}' --organization '$do' --network 172.31.0.0 --mask 255.255.0.0 --location '$location_name'"
    subnet_id=$( h_out "--output yaml subnet info --name '$subnet_name'" | grep '^Id:' | cut -d ' ' -f 2 )
    a 45-subnet-add-rex-capsule-$capsule_name.log satellite6 -m "shell" -a "curl --silent --insecure -u {{ sat_user }}:{{ sat_pass }} -X PUT -H 'Accept: application/json' -H 'Content-Type: application/json' https://localhost//api/v2/subnets/$subnet_id -d '{\"subnet\": {\"remote_execution_proxy_ids\": [\"$capsule_id\"]}}'"
    h 41-hostgroup-create-$capsule_name.log "hostgroup create --content-view 'Default Organization View' --lifecycle-environment Library --name '$hostgroup_name' --query-organization '$do' --subnet '$subnet_name'"
done
h 43-ak-create.log "activation-key create --content-view 'Default Organization View' --lifecycle-environment Library --name ActivationKey --organization '$do'"
h subs-list-tools.log "--csv subscription list --organization '$do' --search 'name = SatToolsProduct'"
tools_subs_id=$( tail -n 1 $logs/subs-list-tools.log | cut -d ',' -f 1 )
h ak-add-subs-tools.log "activation-key add-subscription --organization '$do' --name ActivationKey --subscription-id '$tools_subs_id'"
h subs-list-employee.log "--csv subscription list --organization '$do' --search 'name = \"Employee SKU\"'"
employee_subs_id=$( tail -n 1 $logs/subs-list-employee.log | cut -d ',' -f 1 )
h ak-add-subs-employee.log "activation-key add-subscription --organization '$do' --name ActivationKey --subscription-id '$employee_subs_id'"


section "Register"
for i in $( seq $registrations_iterations ); do
    ap 44-register-$i.log playbooks/tests/registrations.yaml -e "size=$registrations_per_docker_hosts tags=untagged,REG,REM bootstrap_activationkey='ActivationKey' bootstrap_hostgroup='hostgroup-for-{{ tests_registration_target }}' grepper='Register' registration_logs='$logs/44-register-docker-host-client-logs'"
    e Register $logs/44-register-$i.log
    s $wait_interval
done


section "Remote execution"
h 50-rex-set-via-ip.log "settings set --name remote_execution_connect_by_ip --value true"
a 51-rex-cleanup-know_hosts.log satellite6 -m "shell" -a "rm -rf /usr/share/foreman-proxy/.ssh/known_hosts*"
h 52-rex-date.log "job-invocation create --inputs \"command='date'\" --job-template 'Run Command - SSH Default' --search-query 'name ~ container'"
s $wait_interval
h 52-rex-date-ansible.log "job-invocation create --inputs \"command='date'\" --job-template 'Run Command - Ansible Default' --search-query 'name ~ container'"
s $wait_interval
h 53-rex-sm-facts-update.log "job-invocation create --inputs \"command='subscription-manager facts --update'\" --job-template 'Run Command - SSH Default' --search-query 'name ~ container'"
s $wait_interval
h 54-rex-katello-package-upload.log "job-invocation create --inputs \"command='katello-package-upload --force'\" --job-template 'Run Command - SSH Default' --search-query 'name ~ container'"
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


section "Preparing Puppet environment"
ap satellite-puppet-single-cv.log playbooks/tests/puppet-single-setup.yaml &
ap satellite-puppet-big-cv.log playbooks/tests/puppet-big-setup.yaml &
a clear-used-containers-counter.log -m shell -a "echo 0 >/root/container-used-count" docker-hosts &
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


###section "Formatting results"
###table_row "01-manifest-upload-[0-9]\+.log" "Manifest upload"
###table_row "12-repo-sync-rhel7.log" "Sync RHEL7 (immediate)"
###table_row "12-repo-sync-rhel6.log" "Sync RHEL6 (on-demand)"
###table_row "12-repo-sync-rhel7optional.log" "Sync RHEL7 Optional (on-demand)"
###table_row "21-cv-all-publish.log" "Publish big CV"
###table_row "23-cv-all-promote-[0-9]\+.log" "Promote big CV"
###table_row "33-cv-filtered-publish.log" "Publish smaller filtered CV"
###table_row "44-register-[0-9]\+.log" "Register bunch of containers" "Register"
###table_row "52-rex-date.log" "ReX 'date' on all containers"
###table_row "53-rex-sm-facts-update.log" "ReX 'subscription-manager facts --update' on all containers"
###table_row "54-rex-katello-package-upload.log" "ReX 'katello-package-upload --force' on all containers"
###table_row "60-generate-applicability.log" "Generate errata applicability on all profiles" "GenerateApplicability"
###table_row "61-hammer-list.log" "Run hammer host list --per-page 100" "HammerHostList"
###for i in dashboard job_invocations foreman_tasks_tasks hosts templates_provisioning_templates hostgroups smart_proxies domains; do
###    table_row "62-some-webui-pages.log" "UI page reload on $i" "WebUIPage${ui_pages_reloads}_${i}"
###done
###for concurency in $( echo "$puppet_one_concurency" | tr " " "\n" | sort -nu ); do
###    table_row "$concurency-PuppetOne.*\.log" "Registering $concurency * <hosts> Puppet clients; scenario 'One'" "RegisterPuppet"
###done
###for concurency in $( echo "$puppet_bunch_concurency" | tr " " "\n" | sort -nu ); do
###    table_row "$concurency-PuppetBunch.*\.log" "Registering $concurency * <hosts> Puppet clients; scenario 'Bunch'" "RegisterPuppet"
###done

junit_upload
