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
opts_adhoc="$opts --user root"


section "Checking environment"
a 00-info-rpm-qa.log satellite6 -m "shell" -a "rpm -qa | sort"
a 00-info-hostname.log satellite6 -m "shell" -a "hostname"
a 00-check-ping-sat.log docker-hosts -m "shell" -a "ping -c 3 {{ groups['satellite6']|first }}"
a 00-check-hammer-ping.log satellite6 -m "shell" -a "! ( hammer $hammer_opts ping | grep 'Status:' | grep -v 'ok$' )"
a 00-info-rpm-q-satellite.log satellite6 -m "shell" -a "rpm -q satellite"
satellite_version=$( tail -n 1 $logs/00-info-rpm-q-satellite.log ); echo "$satellite_version" | grep '^satellite-6\.'   # make sure it was detected correctly

junit_upload
