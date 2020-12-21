#!/bin/bash

source experiment/run-library.sh

manifest="${PARAM_manifest:-conf/contperf/manifest.zip}"
inventory="${PARAM_inventory:-conf/contperf/inventory.ini}"
private_key="${PARAM_private_key:-conf/contperf/id_rsa_perf}"

wait_interval=${PARAM_wait_interval:-50}

ui_pages_reloads="${PARAM_ui_pages_reloads:-10}"

do="Default Organization"
dl="Default Location"

opts="--forks 100 -i $inventory --private-key $private_key"
opts_adhoc="$opts --user root"


section "Checking environment"
extended=false generic_environment_check

section "WebUI test"
ap 10-some-webui-pages.log -e "ui_pages_reloads=$ui_pages_reloads" playbooks/tests/some-webui-pages.yaml
s $wait_interval
ap 15-siege-webui.log -e "siege_result_json_file=../../$logs/15-siege-webui.json" playbooks/tests/siege-webui.yaml

section "Summary"
# Showing results for playbooks/tests/some-webui-pages.yaml
e WebUIPage10_dashboard $logs/10-some-webui-pages.log
e WebUIPage10_job_invocations $logs/10-some-webui-pages.log
e WebUIPage10_foreman_tasks_tasks $logs/10-some-webui-pages.log
e WebUIPage10_foreman_tasks_api_tasks_include_permissions_true $logs/10-some-webui-pages.log
e WebUIPage10_hosts $logs/10-some-webui-pages.log
e WebUIPage10_templates_provisioning_templates $logs/10-some-webui-pages.log
e WebUIPage10_hostgroups $logs/10-some-webui-pages.log
e WebUIPage10_smart_proxies $logs/10-some-webui-pages.log
e WebUIPage10_domains $logs/10-some-webui-pages.log
e WebUIPage10_audits $logs/10-some-webui-pages.log
e WebUIPage10_katello_api_v2_subscriptions_organization_id_1 $logs/10-some-webui-pages.log
e WebUIPage10_katello_api_v2_products_organization_id_1 $logs/10-some-webui-pages.log
e WebUIPage10_katello_api_v2_content_views_nondefault_true_organization_id_1 $logs/10-some-webui-pages.log
e WebUIPage10_katello_api_v2_packages_organization_id_1 $logs/10-some-webui-pages.log
# Showing results for playbooks/tests/siege-webui.yaml
log "Siege results: $( cat $logs/15-siege-webui.json )"

junit_upload
