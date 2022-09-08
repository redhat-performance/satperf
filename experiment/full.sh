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

ui_pages_concurrency="${PARAM_ui_pages_concurrency:-10}"
ui_pages_duration="${PARAM_ui_pages_duration:-300}"

do="Default Organization"
dl="Default Location"

opts="--forks 100 -i $inventory --private-key $private_key"
opts_adhoc="$opts --user root -e @conf/satperf.yaml -e @conf/satperf.local.yaml"


section "Checking environment"
generic_environment_check


section "Prepare for Red Hat content"
skip_measurement='true' h 00-ensure-loc-in-org.log "organization add-location --name '$do' --location '$dl'"
skip_measurement='true' ap 01-manifest-excercise.log playbooks/tests/manifest-excercise.yaml -e "manifest=../../$manifest"
e ManifestUpload $logs/01-manifest-excercise.log
e ManifestRefresh $logs/01-manifest-excercise.log
e ManifestDelete $logs/01-manifest-excercise.log
skip_measurement='true' h 02-manifest-upload.log "subscription upload --file '/root/manifest-auto.zip' --organization '$do'"
skip_measurement='true' h 03-simple-content-access-disable.log "simple-content-access disable --organization '$do'"
s $wait_interval


section "Sync from mirror"
skip_measurement='true' h 00-set-local-cdn-mirror.log "organization update --name '$do' --redhat-repository-url '$cdn_url_mirror'"
skip_measurement='true' h 10-reposet-enable-rhel7.log  "repository-set enable --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server (RPMs)' --releasever '7Server' --basearch 'x86_64'"
skip_measurement='true' h 10-reposet-enable-rhel6.log  "repository-set enable --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 6 Server (RPMs)' --releasever '6Server' --basearch 'x86_64'"
skip_measurement='true' h 10-reposet-enable-rhel7optional.log "repository-set enable --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server - Optional (RPMs)' --releasever '7Server' --basearch 'x86_64'"
skip_measurement='true' h 10-reposet-enable-rhel8baseos.log  "repository-set enable --organization '$do' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - BaseOS (RPMs)' --releasever '8' --basearch 'x86_64'"
skip_measurement='true' h 10-reposet-enable-rhel8appstream.log  "repository-set enable --organization '$do' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - AppStream (RPMs)' --releasever '8' --basearch 'x86_64'"
skip_measurement='true' h 11-repo-immediate-rhel7.log "repository update --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server' --download-policy 'immediate'"
h 12-repo-sync-rhel7.log "repository synchronize --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server'"
s $wait_interval
h 12-repo-sync-rhel6.log "repository synchronize --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 6 Server RPMs x86_64 6Server'"
s $wait_interval
h 12-repo-sync-rhel8baseos.log "repository synchronize --organization '$do' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - BaseOS RPMs 8'"
s $wait_interval
h 12-repo-sync-rhel8appstream.log "repository synchronize --organization '$do' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - AppStream RPMs 8'"
s $wait_interval
h 12-repo-sync-rhel7optional.log "repository synchronize --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server - Optional RPMs x86_64 7Server'"
s $wait_interval

section "Synchronise capsules"
tmp=$( mktemp )
h_out "--no-headers --csv capsule list --organization '$do'" | grep '^[0-9]\+,' >$tmp
for capsule_id in $( cat $tmp | cut -d ',' -f 1 | grep -v -e '1' ); do
    h 13-capsule-sync-$capsule_id.log "capsule content synchronize --organization '$do' --id '$capsule_id'"
done
s $wait_interval

section "Publish and promote big CV"
rids="$( get_repo_id 'Red Hat Enterprise Linux Server' 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server' )"
rids="$rids,$( get_repo_id 'Red Hat Enterprise Linux Server' 'Red Hat Enterprise Linux 6 Server RPMs x86_64 6Server' )"
rids="$rids,$( get_repo_id 'Red Hat Enterprise Linux Server' 'Red Hat Enterprise Linux 7 Server - Optional RPMs x86_64 7Server' )"
skip_measurement='true' h 20-cv-create-all.log "content-view create --organization '$do' --repository-ids '$rids' --name 'BenchContentView'"
h 21-cv-all-publish.log "content-view publish --organization '$do' --name 'BenchContentView'"
s $wait_interval
skip_measurement='true' h 22-le-create-1.log "lifecycle-environment create --organization '$do' --prior 'Library' --name 'BenchLifeEnvAAA'"
skip_measurement='true' h 22-le-create-2.log "lifecycle-environment create --organization '$do' --prior 'BenchLifeEnvAAA' --name 'BenchLifeEnvBBB'"
skip_measurement='true' h 22-le-create-3.log "lifecycle-environment create --organization '$do' --prior 'BenchLifeEnvBBB' --name 'BenchLifeEnvCCC'"
h 23-cv-all-promote-1.log "content-view version promote --organization '$do' --content-view 'BenchContentView' --to-lifecycle-environment 'Library' --to-lifecycle-environment 'BenchLifeEnvAAA'"
s $wait_interval
h 23-cv-all-promote-2.log "content-view version promote --organization '$do' --content-view 'BenchContentView' --to-lifecycle-environment 'BenchLifeEnvAAA' --to-lifecycle-environment 'BenchLifeEnvBBB'"
s $wait_interval
h 23-cv-all-promote-3.log "content-view version promote --organization '$do' --content-view 'BenchContentView' --to-lifecycle-environment 'BenchLifeEnvBBB' --to-lifecycle-environment 'BenchLifeEnvCCC'"
s $wait_interval


section "Publish and promote filtered CV"
rids="$( get_repo_id 'Red Hat Enterprise Linux Server' 'Red Hat Enterprise Linux 6 Server RPMs x86_64 6Server' )"
skip_measurement='true' h 30-cv-create-filtered.log "content-view create --organization '$do' --repository-ids '$rids' --name 'BenchFilteredContentView'"
skip_measurement='true' h 31-filter-create-1.log "content-view filter create --organization '$do' --type erratum --inclusion true --content-view BenchFilteredContentView --name BenchFilterAAA"
skip_measurement='true' h 31-filter-create-2.log "content-view filter create --organization '$do' --type erratum --inclusion true --content-view BenchFilteredContentView --name BenchFilterBBB"
skip_measurement='true' h 32-rule-create-1.log "content-view filter rule create --content-view BenchFilteredContentView --content-view-filter BenchFilterAAA --date-type 'issued' --start-date 2016-01-01 --end-date 2017-10-01 --organization '$do' --types enhancement,bugfix,security"
skip_measurement='true' h 32-rule-create-2.log "content-view filter rule create --content-view BenchFilteredContentView --content-view-filter BenchFilterBBB --date-type 'updated' --start-date 2016-01-01 --end-date 2018-01-01 --organization '$do' --types security"
h 33-cv-filtered-publish.log "content-view publish --organization '$do' --name 'BenchFilteredContentView'"
s $wait_interval


export skip_measurement='true'
section "Sync from CDN do not measure"   # do not measure becasue of unpredictable network latency
h 00b-set-cdn-stage.log "organization update --name '$do' --redhat-repository-url '$cdn_url_full'"
h 00b-manifest-refresh.log "subscription refresh-manifest --organization '$do'"
h 12b-repo-sync-rhel7.log "repository synchronize --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server'" &
h 12b-repo-sync-rhel6.log "repository synchronize --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 6 Server RPMs x86_64 6Server'" &
h 12b-repo-sync-rhel7optional.log "repository synchronize --organization '$do' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server - Optional RPMs x86_64 7Server'" &
h 12b-repo-sync-rhel8baseos.log "repository synchronize --organization '$do' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - BaseOS RPMs 8'" &
h 12b-repo-sync-rhel8appstream.log "repository synchronize --organization '$do' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - AppStream RPMs 8'" &
wait
s $wait_interval
unset skip_measurement


section "Sync Tools repo"
skip_measurement='true' h product-create.log "product create --organization '$do' --name SatToolsProduct"
skip_measurement='true' h repository-create-sat-tools.log "repository create --organization '$do' --product SatToolsProduct --name SatToolsRepo --content-type yum --url '$repo_sat_tools'"
[ "$repo_sat_tools_puppet" != "none" ] \
    && skip_measurement='true' h repository-create-puppet-upgrade.log "repository create --organization '$do' --product SatToolsProduct --name SatToolsPuppetRepo --content-type yum --url '$repo_sat_tools_puppet'"
h repository-sync-sat-tools.log "repository synchronize --organization '$do' --product SatToolsProduct --name SatToolsRepo" &
[ "$repo_sat_tools_puppet" != "none" ] \
    && skip_measurement='true' h repository-sync-puppet-upgrade.log "repository synchronize --organization '$do' --product SatToolsProduct --name SatToolsPuppetRepo" &
wait
s $wait_interval


export skip_measurement='true'
section "Synchronise capsules again do not measure"   # We just added up2date content from CDN and SatToolsRepo, so no reason to measure this now
tmp=$( mktemp )
h_out "--no-headers --csv capsule list --organization '$do'" | grep '^[0-9]\+,' >$tmp
for capsule_id in $( cat $tmp | cut -d ',' -f 1 | grep -v '1' ); do
    h 13b-capsule-sync-$capsule_id.log "capsule content synchronize --organization '$do' --id '$capsule_id'"
done
s $wait_interval
unset skip_measurement


section "Prepare for registrations"
h_out "--no-headers --csv domain list --search 'name = {{ containers_domain }}'" | grep --quiet '^[0-9]\+,' \
    || skip_measurement='true' h 42-domain-create.log "domain create --name '{{ containers_domain }}' --organizations '$do'"
tmp=$( mktemp )
h_out "--no-headers --csv location list --organization '$do'" | grep '^[0-9]\+,' >$tmp
location_ids=$( cut -d ',' -f 1 $tmp | tr '\n' ',' | sed 's/,$//' )
skip_measurement='true' h 42-domain-update.log "domain update --name '{{ containers_domain }}' --organizations '$do' --location-ids '$location_ids'"

skip_measurement='true' h 43-ak-create.log "activation-key create --content-view '$do View' --lifecycle-environment Library --name ActivationKey --organization '$do'"
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
        || skip_measurement='true' h 44-subnet-create-$capsule_name.log "subnet create --name '$subnet_name' --ipam None --domains '{{ containers_domain }}' --organization '$do' --network 172.0.0.0 --mask 255.0.0.0 --location '$location_name'"
    subnet_id=$( h_out "--output yaml subnet info --name '$subnet_name'" | grep '^Id:' | cut -d ' ' -f 2 )
    skip_measurement='true' a 45-subnet-add-rex-capsule-$capsule_name.log satellite6 -m "shell" -a "curl --silent --insecure -u {{ sat_user }}:{{ sat_pass }} -X PUT -H 'Accept: application/json' -H 'Content-Type: application/json' https://localhost//api/v2/subnets/$subnet_id -d '{\"subnet\": {\"remote_execution_proxy_ids\": [\"$capsule_id\"]}}'"
    h_out "--no-headers --csv hostgroup list --search 'name = $hostgroup_name'" | grep --quiet '^[0-9]\+,' \
        || skip_measurement='true' ap 41-hostgroup-create-$capsule_name.log playbooks/satellite/hostgroup-create.yaml -e "Default_Organization='$do' hostgroup_name=$hostgroup_name subnet_name=$subnet_name"
done

skip_measurement='true' ap 44-recreate-client-scripts.log playbooks/satellite/client-scripts.yaml -e "registration_hostgroup=hostgroup-for-{{ tests_registration_target }}"


section "Register"
for i in $( seq $registrations_iterations ); do
    skip_measurement='true' ap 44-register-$i.log playbooks/tests/registrations.yaml -e "size=$registrations_per_docker_hosts registration_logs='../../$logs/44-register-docker-host-client-logs'"
    s $wait_interval
done
grep Register $logs/44-register-*.log >$logs/44-register-overall.log
e Register $logs/44-register-overall.log


section "Remote execution"
skip_measurement='true' h 50-rex-set-via-ip.log "settings set --name remote_execution_connect_by_ip --value true"
skip_measurement='true' a 51-rex-cleanup-know_hosts.log satellite6 -m "shell" -a "rm -rf /usr/share/foreman-proxy/.ssh/known_hosts*"
job_template_ansible_default='Run Command - Ansible Default'
if vercmp_ge "$satellite_version" "6.12.0"; then
    job_template_ssh_default='Run Command - Script Default'
else
    job_template_ssh_default='Run Command - SSH Default'
fi
skip_measurement='true' h 55-rex-date.log "job-invocation create --async --inputs \"command='date'\" --job-template '$job_template_ssh_default' --search-query 'name ~ container'"
j $logs/55-rex-date.log
s $wait_interval
skip_measurement='true' h 56-rex-date-ansible.log "job-invocation create --async --inputs \"command='date'\" --job-template '$job_template_ansible_default' --search-query 'name ~ container'"
j $logs/56-rex-date-ansible.log
s $wait_interval
skip_measurement='true' h 57-rex-sm-facts-update.log "job-invocation create --async --inputs \"command='subscription-manager facts --update'\" --job-template '$job_template_ssh_default' --search-query 'name ~ container'"
j $logs/57-rex-sm-facts-update.log
s $wait_interval
skip_measurement='true' h 58-rex-uploadprofile.log "job-invocation create --async --inputs \"command='dnf uploadprofile --force-upload'\" --job-template '$job_template_ssh_default' --search-query 'name ~ container'"
j $logs/58-rex-uploadprofile.log
s $wait_interval


section "Misc simple tests"
skip_measurement='true' ap 61-hammer-list.log playbooks/tests/hammer-list.yaml
e HammerHostList $logs/61-hammer-list.log
s $wait_interval
rm -f /tmp/status-data-webui-pages.json
skip_measurement='true' ap 62-webui-pages.log -e "ui_pages_concurrency=$ui_pages_concurrency ui_pages_duration=$ui_pages_duration" playbooks/tests/webui-pages.yaml
STATUS_DATA_FILE=/tmp/status-data-webui-pages.json e WebUIPagesTest_c${ui_pages_concurrency}_d${ui_pages_duration} $logs/62-webui-pages.log
s $wait_interval
a 63-foreman_inventory_upload-report-generate.log satellite6 -m "shell" -a "export organization_id={{ sat_orgid }}; export target=/var/lib/foreman/red_hat_inventory/generated_reports/; /usr/sbin/foreman-rake rh_cloud_inventory:report:generate"
s $wait_interval


section "BackupTest"
skip_measurement='true' ap 70-backup.log playbooks/tests/sat-backup.yaml
e BackupOnline $logs/70-backup.log
e BackupOffline $logs/70-backup.log
e Restore $logs/70-backup.log


section "Sosreport"
ap sosreporter-gatherer.log playbooks/satellite/sosreport_gatherer.yaml -e "sosreport_gatherer_local_dir='../../$logs/sosreport/'"

junit_upload
