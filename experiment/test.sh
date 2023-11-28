#!/bin/bash

source experiment/run-library.sh

manifest="${PARAM_manifest:-conf/contperf/manifest_SCA.zip}"
inventory="${PARAM_inventory:-conf/contperf/inventory.${branch}.ini}"

registrations_per_docker_hosts=${PARAM_registrations_per_docker_hosts:-5}
registrations_iterations=${PARAM_registrations_iterations:-20}

puppet_one_concurency="${PARAM_puppet_one_concurency:-5 15 30}"
puppet_bunch_concurency="${PARAM_puppet_bunch_concurency:-2 6 10 14 18}"

cdn_url_mirror="${PARAM_cdn_url_mirror:-https://cdn.redhat.com/}"
cdn_url_full="${PARAM_cdn_url_full:-https://cdn.redhat.com/}"

ui_pages_reloads="${PARAM_ui_pages_reloads:-10}"

dl="Default Location"

opts="--forks 100 -i $inventory"
opts_adhoc="$opts -e branch='$branch'"


section "Checking environment"
generic_environment_check false

junit_upload
