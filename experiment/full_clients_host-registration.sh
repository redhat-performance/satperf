#!/bin/bash

source experiment/run-library.sh

organization="${PARAM_organization:-Default Organization}"
manifest="${PARAM_manifest:-conf/contperf/manifest_SCA.zip}"
inventory="${PARAM_inventory:-conf/contperf/inventory.ini}"
local_conf="${PARAM_local_conf:-conf/satperf.local.yaml}"

concurrent_registrations=${PARAM_concurrent_registrations:-125}
wait_interval=${PARAM_wait_interval:-30}

puppet_one_concurency="${PARAM_puppet_one_concurency:-5 15 30}"
puppet_bunch_concurency="${PARAM_puppet_bunch_concurency:-2 6 10 14 18}"

cdn_url_mirror="${PARAM_cdn_url_mirror:-https://cdn.redhat.com/}"
cdn_url_full="${PARAM_cdn_url_full:-https://cdn.redhat.com/}"

repo_sat_client_7="${PARAM_repo_sat_client_7:-http://mirror.example.com/Satellite_Client_7_x86_64/}"
repo_sat_client_8="${PARAM_repo_sat_client_8:-http://mirror.example.com/Satellite_Client_8_x86_64/}"
repo_sat_client_9="${PARAM_repo_sat_client_9:-http://mirror.example.com/Satellite_Client_9_x86_64/}"

rhel_subscription="${PARAM_rhel_subscription:-Red Hat Enterprise Linux Server, Standard (Physical or Virtual Nodes)}"

ui_pages_concurrency="${PARAM_ui_pages_concurrency:-10}"
ui_pages_duration="${PARAM_ui_pages_duration:-300}"

dl="Default Location"

opts="--forks 100 -i $inventory"
opts_adhoc="$opts -e @conf/satperf.yaml -e @$local_conf"


section "Checking environment"
generic_environment_check


section "Prepare for Red Hat content"
h_out "--no-headers --csv organization list --fields name" | grep --quiet "^$organization$" \
  || h 00-ensure-org.log "organization create --name '$organization'"
skip_measurement='true' h 00-ensure-loc-in-org.log "organization add-location --name '$organization' --location '$dl'"
skip_measurement='true' ap 01-manifest-excercise.log playbooks/tests/manifest-excercise.yaml -e "manifest=../../$manifest"
e ManifestUpload $logs/01-manifest-excercise.log
e ManifestRefresh $logs/01-manifest-excercise.log
e ManifestDelete $logs/01-manifest-excercise.log
skip_measurement='true' h 02-manifest-upload.log "subscription upload --file '/root/manifest-auto.zip' --organization '$organization'"
s $wait_interval


section "Sync from mirror"
skip_measurement='true' h 00-set-local-cdn-mirror.log "organization update --name '$organization' --redhat-repository-url '$cdn_url_mirror'"

skip_measurement='true' h 00-manifest-refresh.log "subscription refresh-manifest --organization '$organization'"

skip_measurement='true' h 10-reposet-enable-rhel6.log "repository-set enable --organization '$organization' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 6 Server (RPMs)' --releasever '6Server' --basearch 'x86_64'"
h 12-repo-sync-rhel6.log "repository synchronize --organization '$organization' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 6 Server RPMs x86_64 6Server'"
s $wait_interval

skip_measurement='true' h 10-reposet-enable-rhel7.log "repository-set enable --organization '$organization' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server (RPMs)' --releasever '7Server' --basearch 'x86_64'"
skip_measurement='true' h 11-repo-immediate-rhel7.log "repository update --organization '$organization' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server' --download-policy 'immediate'"
h 12-repo-sync-rhel7.log "repository synchronize --organization '$organization' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server'"
s $wait_interval
skip_measurement='true' h 10-reposet-enable-rhel7optional.log "repository-set enable --organization '$organization' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server - Optional (RPMs)' --releasever '7Server' --basearch 'x86_64'"
h 12-repo-sync-rhel7optional.log "repository synchronize --organization '$organization' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server - Optional RPMs x86_64 7Server'"
s $wait_interval

skip_measurement='true' h 10-reposet-enable-rhel8baseos.log "repository-set enable --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - BaseOS (RPMs)' --releasever '8' --basearch 'x86_64'"
h 12-repo-sync-rhel8baseos.log "repository synchronize --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - BaseOS RPMs 8'"
s $wait_interval
skip_measurement='true' h 10-reposet-enable-rhel8appstream.log "repository-set enable --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - AppStream (RPMs)' --releasever '8' --basearch 'x86_64'"
h 12-repo-sync-rhel8baseos.log "repository synchronize --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - BaseOS RPMs 8'"
s $wait_interval
h 12-repo-sync-rhel8appstream.log "repository synchronize --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - AppStream RPMs 8'"
s $wait_interval

skip_measurement='true' h 10-reposet-enable-rhel9baseos.log "repository-set enable --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 9 for x86_64 - BaseOS (RPMs)' --releasever '9' --basearch 'x86_64'"
h 12-repo-sync-rhel9baseos.log "repository synchronize --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 9 for x86_64 - BaseOS RPMs 9'"
s $wait_interval
skip_measurement='true' h 10-reposet-enable-rhel9appstream.log "repository-set enable --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 9 for x86_64 - AppStream (RPMs)' --releasever '9' --basearch 'x86_64'"
h 12-repo-sync-rhel9appstream.log "repository synchronize --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 9 for x86_64 - AppStream RPMs 9'"
s $wait_interval


section "Synchronise capsules"
tmp=$( mktemp )

h_out "--no-headers --csv capsule list --organization '$organization'" | grep '^[0-9]\+,' >$tmp
for capsule_id in $( cat $tmp | cut -d ',' -f 1 | grep -v -e '1' ); do
    skip_measurement='true' h 13-capsule-add-library-lce-$capsule_id.log "capsule content add-lifecycle-environment  --organization '$organization' --id '$capsule_id' --lifecycle-environment 'Library'"
    h 13-capsule-sync-$capsule_id.log "capsule content synchronize --organization '$organization' --id '$capsule_id'"
done
s $wait_interval


section "Publish and promote big CV"
rids="$( get_repo_id 'Red Hat Enterprise Linux Server' 'Red Hat Enterprise Linux 6 Server RPMs x86_64 6Server' )"
rids="$rids,$( get_repo_id 'Red Hat Enterprise Linux Server' 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server' )"
rids="$rids,$( get_repo_id 'Red Hat Enterprise Linux Server' 'Red Hat Enterprise Linux 7 Server - Optional RPMs x86_64 7Server' )"

skip_measurement='true' h 20-cv-create-all.log "content-view create --organization '$organization' --repository-ids '$rids' --name 'BenchContentView'"
h 21-cv-all-publish.log "content-view publish --organization '$organization' --name 'BenchContentView'"
s $wait_interval

skip_measurement='true' h 22-le-create-1.log "lifecycle-environment create --organization '$organization' --prior 'Library' --name 'BenchLifeEnvAAA'"
skip_measurement='true' h 22-le-create-2.log "lifecycle-environment create --organization '$organization' --prior 'BenchLifeEnvAAA' --name 'BenchLifeEnvBBB'"
skip_measurement='true' h 22-le-create-3.log "lifecycle-environment create --organization '$organization' --prior 'BenchLifeEnvBBB' --name 'BenchLifeEnvCCC'"

h 23-cv-all-promote-1.log "content-view version promote --organization '$organization' --content-view 'BenchContentView' --to-lifecycle-environment 'Library' --to-lifecycle-environment 'BenchLifeEnvAAA'"
s $wait_interval
h 23-cv-all-promote-2.log "content-view version promote --organization '$organization' --content-view 'BenchContentView' --to-lifecycle-environment 'BenchLifeEnvAAA' --to-lifecycle-environment 'BenchLifeEnvBBB'"
s $wait_interval
h 23-cv-all-promote-3.log "content-view version promote --organization '$organization' --content-view 'BenchContentView' --to-lifecycle-environment 'BenchLifeEnvBBB' --to-lifecycle-environment 'BenchLifeEnvCCC'"
s $wait_interval


section "Publish and promote filtered CV"
rids="$( get_repo_id 'Red Hat Enterprise Linux Server' 'Red Hat Enterprise Linux 6 Server RPMs x86_64 6Server' )"

skip_measurement='true' h 30-cv-create-filtered.log "content-view create --organization '$organization' --repository-ids '$rids' --name 'BenchFilteredContentView'"

skip_measurement='true' h 31-filter-create-1.log "content-view filter create --organization '$organization' --type erratum --inclusion true --content-view BenchFilteredContentView --name BenchFilterAAA"
skip_measurement='true' h 31-filter-create-2.log "content-view filter create --organization '$organization' --type erratum --inclusion true --content-view BenchFilteredContentView --name BenchFilterBBB"

skip_measurement='true' h 32-rule-create-1.log "content-view filter rule create --content-view BenchFilteredContentView --content-view-filter BenchFilterAAA --date-type 'issued' --start-date 2016-01-01 --end-date 2017-10-01 --organization '$organization' --types enhancement,bugfix,security"
skip_measurement='true' h 32-rule-create-2.log "content-view filter rule create --content-view BenchFilteredContentView --content-view-filter BenchFilterBBB --date-type 'updated' --start-date 2016-01-01 --end-date 2018-01-01 --organization '$organization' --types security"

h 33-cv-filtered-publish.log "content-view publish --organization '$organization' --name 'BenchFilteredContentView'"
s $wait_interval


export skip_measurement='true'
section "Sync from CDN do not measure"   # do not measure becasue of unpredictable network latency
h 00b-set-cdn-stage.log "organization update --name '$organization' --redhat-repository-url '$cdn_url_full'"

h 00b-manifest-refresh.log "subscription refresh-manifest --organization '$organization'"

h 12b-repo-sync-rhel6.log "repository synchronize --organization '$organization' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 6 Server RPMs x86_64 6Server'" &

h 12b-repo-sync-rhel7.log "repository synchronize --organization '$organization' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server'" &
h 12b-repo-sync-rhel7optional.log "repository synchronize --organization '$organization' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server - Optional RPMs x86_64 7Server'" &

h 12b-repo-sync-rhel8baseos.log "repository synchronize --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - BaseOS RPMs 8'" &
h 12b-repo-sync-rhel8appstream.log "repository synchronize --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 8 for x86_64 - AppStream RPMs 8'" &

h 12b-repo-sync-rhel9baseos.log "repository synchronize --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 9 for x86_64 - BaseOS RPMs 9'" &
h 12b-repo-sync-rhel9appstream.log "repository synchronize --organization '$organization' --product 'Red Hat Enterprise Linux for x86_64' --name 'Red Hat Enterprise Linux 9 for x86_64 - AppStream RPMs 9'" &
wait
unset skip_measurement


export skip_measurement='true'
section "Sync Client repos"
h 30-sat-client-product-create.log "product create --organization '$organization' --name SatClientProduct"

h 30-repository-create-sat-client_7.log "repository create --organization '$organization' --product SatClientProduct --name SatClient7Repo --content-type yum --url '$repo_sat_client_7'"
h 30-repository-sync-sat-client_7.log "repository synchronize --organization '$organization' --product SatClientProduct --name SatClient7Repo" &

h 30-repository-create-sat-client_8.log "repository create --organization '$organization' --product SatClientProduct --name SatClient8Repo --content-type yum --url '$repo_sat_client_8'"
h 30-repository-sync-sat-client_8.log "repository synchronize --organization '$organization' --product SatClientProduct --name SatClient8Repo" &

h 30-repository-create-sat-client_9.log "repository create --organization '$organization' --product SatClientProduct --name SatClient9Repo --content-type yum --url '$repo_sat_client_9'"
h 30-repository-sync-sat-client_9.log "repository synchronize --organization '$organization' --product SatClientProduct --name SatClient9Repo" &
wait
unset skip_measurement


export skip_measurement='true'
section "Synchronise capsules again"   # We just added up2date content from CDN and SatClient7Repo, so no reason to measure this now
tmp=$( mktemp )

h_out "--no-headers --csv capsule list --organization '$organization'" | grep '^[0-9]\+,' >$tmp
for capsule_id in $( cat $tmp | cut -d ',' -f 1 | grep -v '1' ); do
    h 13b-capsule-sync-$capsule_id.log "capsule content synchronize --organization '$organization' --id '$capsule_id'"
done
s $wait_interval
unset skip_measurement


export skip_measurement='true'
section "Prepare for registrations"
h_out "--no-headers --csv domain list --search 'name = {{ domain }}'" | grep --quiet '^[0-9]\+,' \
  || h 42-domain-create.log "domain create --name '{{ domain }}' --organizations '$organization'"
tmp=$( mktemp )
h_out "--no-headers --csv location list --organization '$organization'" | grep '^[0-9]\+,' >$tmp
location_ids=$( cut -d ',' -f 1 $tmp | tr '\n' ',' | sed 's/,$//' )
h 42-domain-update.log "domain update --name '{{ domain }}' --organizations '$organization' --location-ids '$location_ids'"

h 43-ak-create.log "activation-key create --content-view '$organization View' --lifecycle-environment Library --name ActivationKey --organization '$organization'"
h_out "--csv subscription list --organization '$organization' --search 'name = \"$rhel_subscription\"'" >$logs/subs-list-rhel.log
rhel_subs_id=$( tail -n 1 $logs/subs-list-rhel.log | cut -d ',' -f 1 )
h 43-ak-add-subs-rhel.log "activation-key add-subscription --organization '$organization' --name ActivationKey --subscription-id '$rhel_subs_id'"
h_out "--csv subscription list --organization '$organization' --search 'name = SatClientProduct'" >$logs/subs-list-client.log
client_subs_id=$( tail -n 1 $logs/subs-list-client.log | cut -d ',' -f 1 )
h 43-ak-add-subs-client.log "activation-key add-subscription --organization '$organization' --name ActivationKey --subscription-id '$client_subs_id'"

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
      || h 44-subnet-create-$capsule_name.log "subnet create --name '$subnet_name' --ipam None --domains '{{ domain }}' --organization '$organization' --network 172.0.0.0 --mask 255.0.0.0 --location '$location_name'"
    subnet_id=$( h_out "--output yaml subnet info --name '$subnet_name'" | grep '^Id:' | cut -d ' ' -f 2 )
    
    a 45-subnet-add-rex-capsule-$capsule_name.log satellite6 -m "shell" -a "curl --silent --insecure -u {{ sat_user }}:{{ sat_pass }} -X PUT -H 'Accept: application/json' -H 'Content-Type: application/json' https://localhost//api/v2/subnets/$subnet_id -d '{\"subnet\": {\"remote_execution_proxy_ids\": [\"$capsule_id\"]}}'"
    h_out "--no-headers --csv hostgroup list --search 'name = $hostgroup_name'" | grep --quiet '^[0-9]\+,' \
      || ap 41-hostgroup-create-$capsule_name.log playbooks/satellite/hostgroup-create.yaml -e "organization='$organization' hostgroup_name=$hostgroup_name subnet_name=$subnet_name"
done

ap 44-generate-host-registration-command.log playbooks/satellite/host-registration_generate-command.yaml -e "ak=ActivationKey"
ap 44-recreate-client-scripts.log playbooks/satellite/client-scripts.yaml
unset skip_measurement


section "Register"
number_container_hosts=$( ansible -i $inventory --list-hosts container_hosts 2>/dev/null | grep '^  hosts' | sed 's/^  hosts (\([0-9]\+\)):$/\1/' )
number_containers_per_container_host=$( ansible -i $inventory -m debug -a "var=containers_count" container_hosts[0] | awk '/    "containers_count":/ {print $NF}' )
registration_iterations=$(( number_container_hosts * number_containers_per_container_host / concurrent_registrations ))
concurrent_registrations_per_container_host=$(( concurrent_registrations / number_container_hosts ))

log "Going to register $concurrent_registrations_per_container_host hosts per container host ($number_container_hosts available) in $registration_iterations batches."

for i in $( seq $registration_iterations ); do
    skip_measurement='true' ap 44b-register-$i.log playbooks/tests/registrations.yaml \
      -e "size=$concurrent_registrations_per_container_host" \
      -e "registration_logs='../../$logs/44b-register-container-host-client-logs'" \
      -e 're_register_failed_hosts=true' \
      -e "method=clients_host-registration"
    s $wait_interval
done
grep Register $logs/44b-register-*.log >$logs/44b-register-overall.log
e Register $logs/44b-register-overall.log


section "Remote execution"
job_template_ansible_default='Run Command - Ansible Default'
job_template_ssh_default='Run Command - Script Default'

skip_measurement='true' h 50-rex-set-via-ip.log "settings set --name remote_execution_connect_by_ip --value true"
skip_measurement='true' a 51-rex-cleanup-know_hosts.log satellite6 -m "shell" -a "rm -rf /usr/share/foreman-proxy/.ssh/known_hosts*"

skip_measurement='true' h 55-rex-date.log "job-invocation create --async --description-format 'Run %{command} (%{template_name})' --inputs command='date' --job-template '$job_template_ssh_default' --search-query 'name ~ container'"
j $logs/55-rex-date.log
s $wait_interval

skip_measurement='true' h 56-rex-date-ansible.log "job-invocation create --async --description-format 'Run %{command} (%{template_name})' --inputs command='date' --job-template '$job_template_ansible_default' --search-query 'name ~ container'"
j $logs/56-rex-date-ansible.log
s $wait_interval

skip_measurement='true' h 57-rex-sm-facts-update.log "job-invocation create --async --description-format 'Run %{command} (%{template_name})' --inputs command='subscription-manager facts --update' --job-template '$job_template_ssh_default' --search-query 'name ~ container'"
j $logs/57-rex-sm-facts-update.log
s $wait_interval

skip_measurement='true' h 58-rex-uploadprofile.log "job-invocation create --async --description-format 'Run %{command} (%{template_name})' --inputs command='dnf uploadprofile --force-upload' --job-template '$job_template_ssh_default' --search-query 'name ~ container'"
j $logs/58-rex-uploadprofile.log
s $wait_interval


section "Misc simple tests"
ap 61-hammer-list.log playbooks/tests/hammer-list.yaml
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
e BackupOffline $logs/70-backup.log
e RestoreOffline $logs/70-backup.log
e BackupOnline $logs/70-backup.log
e RestoreOnline $logs/70-backup.log


section "Sosreport"
ap sosreporter-gatherer.log playbooks/satellite/sosreport_gatherer.yaml -e "sosreport_gatherer_local_dir='../../$logs/sosreport/'"


junit_upload
