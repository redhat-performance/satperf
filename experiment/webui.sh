#!/bin/bash

source experiment/run-library.sh

organization="${PARAM_organization:-Default Organization}"
manifest="${PARAM_manifest:-conf/contperf/manifest_SCA.zip}"
inventory="${PARAM_inventory:-conf/contperf/inventory.ini}"
private_key="${PARAM_private_key:-conf/contperf/id_rsa_perf}"
local_conf="${PARAM_local_conf:-conf/satperf.local.yaml}"

wait_interval=${PARAM_wait_interval:-50}

ui_pages_concurrency="${PARAM_ui_pages_concurrency:-10}"
ui_pages_duration="${PARAM_ui_pages_duration:-300}"

dl="Default Location"

opts="--forks 100 -i $inventory --private-key $private_key"
opts_adhoc="$opts -e @conf/satperf.yaml -e @$local_conf"


#section "Checking environment"
#generic_environment_check false

section "WebUI test"
rm -f /tmp/status-data-webui-pages.json
skip_measurement='true' ap 10-webui-pages.log \
  -e "ui_pages_concurrency=$ui_pages_concurrency" \
  -e "ui_pages_duration=$ui_pages_duration" \
  playbooks/tests/webui-pages.yaml
STATUS_DATA_FILE=/tmp/status-data-webui-pages.json e WebUIPagesTest_c${ui_pages_concurrency}_d${ui_pages_duration} $logs/10-webui-pages.log

skip_measurement='true' ap 20-webui-static-distributed.log -e "duration=300 concurrency=10 spawn_rate=10 max_static_size=1024" playbooks/tests/webui-static-distributed.yaml

junit_upload
