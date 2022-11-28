#!/bin/bash

source experiment/run-library.sh

organization="${PARAM_organization:-Default Organization}"
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

dl="Default Location"

opts="--forks 100 -i $inventory --private-key $private_key"
opts_adhoc="$opts --user root -e @conf/satperf.yaml -e @conf/satperf.local.yaml"


section "Checking environment"
generic_environment_check false
a 00-restart.log satellite6 -m "shell" -a "foreman-maintain service restart"
s $wait_interval


section "pg_repack testing"
# Manifest refresh
for i in $( seq 5 ); do
    h 03-manifest-refresh-$i.log "subscription refresh-manifest --organization '$organization'"
    s $wait_interval
done

# Re-sync
h 00-set-local-cdn-mirror.log "organization update --name '$organization' --redhat-repository-url '$cdn_url_mirror'"
h 12-repo-sync-rhel7.log "repository synchronize --organization '$organization' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server'"
s $wait_interval
h 12-repo-sync-rhel6.log "repository synchronize --organization '$organization' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 6 Server RPMs x86_64 6Server'"
s $wait_interval
h 12-repo-sync-rhel7optional.log "repository synchronize --organization '$organization' --product 'Red Hat Enterprise Linux Server' --name 'Red Hat Enterprise Linux 7 Server - Optional RPMs x86_64 7Server'"
s $wait_interval

# Publish
h 21-cv-all-publish.log "content-view publish --organization '$organization' --name 'BenchContentView'"
s $wait_interval
h 33-cv-filtered-publish.log "content-view publish --organization '$organization' --name 'BenchFilteredContentView'"
s $wait_interval

# Remote execution
a 51-rex-cleanup-know_hosts.log satellite6 -m "shell" -a "rm -rf /usr/share/foreman-proxy/.ssh/known_hosts*"
h 52-rex-date.log "job-invocation create --description-format 'Run %{command} (%{template_name})' --inputs command='date' --job-template 'Run Command - SSH Default' --search-query 'name ~ container'"
s $wait_interval
h 52-rex-date-ansible.log "job-invocation create --description-format 'Run %{command} (%{template_name})' --inputs command='date' --job-template 'Run Command - Ansible Default' --search-query 'name ~ container'"
s $wait_interval
h 53-rex-sm-facts-update.log "job-invocation create --description-format 'Run %{command} (%{template_name})' --inputs command='subscription-manager facts --update' --job-template 'Run Command - SSH Default' --search-query 'name ~ container'"
s $wait_interval
h 54-rex-uploadprofile.log "job-invocation create --description-format 'Run %{command} (%{template_name})' --inputs command='dnf uploadprofile --force-upload' --job-template 'Run Command - SSH Default' --search-query 'name ~ container'"
s $wait_interval

# Generate applicability
ap 60-generate-applicability.log playbooks/tests/generate-applicability.yaml
e GenerateApplicability $logs/60-generate-applicability.log
s $wait_interval

# Hammer list
ap 61-hammer-list.log playbooks/tests/hammer-list.yaml
e HammerHostList $logs/61-hammer-list.log
s $wait_interval

# WebUI
ap 62-some-webui-pages.log -e "ui_pages_reloads=$ui_pages_reloads" playbooks/tests/some-webui-pages.yaml
e WebUIPage10_dashboard $logs/62-some-webui-pages.log
e WebUIPage10_job_invocations $logs/62-some-webui-pages.log
e WebUIPage10_foreman_tasks_tasks $logs/62-some-webui-pages.log
e WebUIPage10_foreman_tasks_api_tasks_include_permissions_true $logs/62-some-webui-pages.log
e WebUIPage10_hosts $logs/62-some-webui-pages.log
e WebUIPage10_templates_provisioning_templates $logs/62-some-webui-pages.log
e WebUIPage10_hostgroups $logs/62-some-webui-pages.log
e WebUIPage10_smart_proxies $logs/62-some-webui-pages.log
e WebUIPage10_domains $logs/62-some-webui-pages.log
e WebUIPage10_audits $logs/62-some-webui-pages.log
e WebUIPage10_katello_api_v2_subscriptions_organization_id_1 $logs/62-some-webui-pages.log
e WebUIPage10_katello_api_v2_products_organization_id_1 $logs/62-some-webui-pages.log
e WebUIPage10_katello_api_v2_content_views_nondefault_true_organization_id_1 $logs/62-some-webui-pages.log
e WebUIPage10_katello_api_v2_packages_organization_id_1 $logs/62-some-webui-pages.log
s $wait_interval

# Inventory upload
a 63-foreman_inventory_upload-report-generate.log satellite6 -m "shell" -a "export organization_id={{ sat_orgid }}; export target=/var/lib/foreman/red_hat_inventory/generated_reports/; /usr/sbin/foreman-rake foreman_inventory_upload:report:generate"
s $wait_interval

junit_upload
