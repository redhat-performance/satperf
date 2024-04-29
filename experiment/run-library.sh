#!/bin/bash

set -o pipefail
###set -x
set -e


# We need to add an ID to run-bench runs to be able to filter out results from multiple runs. This ID will be appended as
# the last field of lines in measurement.log file.
# The ID should be passed as a argument to the run-bench.sh. If there is no argument passed, default ID will be
# generated based on the current date and time.
marker_date="$(date -u -Iseconds)"
if [ -z "$marker" ]; then
    marker="${1:-run-${marker_date}}"
fi

branch="${PARAM_branch:-satcpt}"
sat_version="${PARAM_sat_version:-stream}"
inventory="${PARAM_inventory:-conf/contperf/inventory.${branch}.ini}"

opts=${opts:-"--forks 100 -i $inventory"}
opts_adhoc=${opts_adhoc:-"$opts"}
logs="$marker"
run_lib_dryrun=false
hammer_opts="-u admin -p changeme"
satellite_version="${satellite_version:-${sat_version}}"   # will be determined automatically by run-bench.sh
katello_version="${katello_version:-N/A}"   # will be determined automatically by run-bench.sh

# Requirements check
#if ! type bc >/dev/null; then
#    echo "ERROR: bc not installed" >&2
#    exit 1
#fi
if ! type ansible >/dev/null; then
    echo "ERROR: ansible not installed" >&2
    exit 1
fi
# if ! type rpmdev-vercmp >/dev/null; then
#     echo "ERROR: rpmdev-vercmp (from rpmdevtools) not installed" >&2
#     exit 1
# fi

# function _vercmp() {
#     # Return values mimic `rpmdev-vercmp` ones
#     if [[ "$1" == "$2" ]]; then
#         return 0
#     elif [[ "$1" == 'stream' ]]; then
#         return 11
#     elif [[ "$2" == 'stream' ]]; then
#         return 12
#     else
#         ver1=$( echo "$1" | sed 's/^\(satellite\|katello\)-//' | sed 's/^\([^-]\+\)-.*$/\1/' )
#         ver2=$( echo "$2" | sed 's/^\(satellite\|katello\)-//' | sed 's/^\([^-]\+\)-.*$/\1/' )

#         rpmdev-vercmp "$ver1" "$ver2"
#     fi
# }

# function vercmp_gt() {
#     # Check if first parameter is greater than second using version string comparision
#     _vercmp "$1" "$2"
#     local rc=$?
#     [ "$rc" -eq 11 ] && return 0 || return 1
# }

# function vercmp_ge() {
#     # Check if first parameter is greater or equal than second using version string comparision
#     _vercmp "$1" "$2"
#     local rc=$?
#     [ "$rc" -eq 11 -o "$rc" -eq 0 ] && return 0 || return 1
# }

function measurement_add() {
    python -c "import csv; import sys; fp=open('$logs/measurement.log','a'); writer=csv.writer(fp); writer.writerow(sys.argv[1:]); fp.close()" "$@"
    if [ "$skip_measurement" != "true" ]; then
        status_data_create "$@"
    fi
}
function measurement_row_field() {
    python -c "import csv; import sys; reader=csv.reader(sys.stdin); print list(reader)[0][int(sys.argv[1])-1]" $1
}

function generic_environment_check() {
    extended=${1:-true}
    restarted=${2:-true}

    export skip_measurement='true'

    a 00-info-rpm-qa.log \
      -m ansible.builtin.shell \
      -a "rpm -qa | sort" \
      satellite6

    a 00-info-hostname.log \
      -m ansible.builtin.shell \
      -a "hostname" \
      satellite6

    a 00-info-ip-a.log \
      -m ansible.builtin.shell \
      -a "ip a" \
      satellite6,capsules,container_hosts

    a 00-check-ping-registration-target.log \
      -m ansible.builtin.shell \
      -a "ping -c 10 {{ tests_registration_target }}" \
      container_hosts

    if $extended; then
        ap 00-remove-hosts-if-any.log \
          playbooks/satellite/satellite-remove-hosts.yaml

        number_container_hosts=$( ansible $opts_adhoc \
          --list-hosts \
          container_hosts 2>/dev/null |
          grep '^  hosts' | sed 's/^  hosts (\([0-9]\+\)):$/\1/' )
        if (( number_container_hosts > 0 )); then
            ap 00-tierdown-containers.log \
              ansible-container-host-mgr/tierdown.yaml

            a 00-delete-private-connection.log \
              -m ansible.builtin.shell \
              -a "nmcli con delete {{ private_nic }} 2>/dev/null; echo" \
              container_hosts

            ap 00-tierup-containers.log \
              ansible-container-host-mgr/tierup.yaml
        fi
    fi

    if $restarted; then
        a 00-satellite-drop-caches.log \
          -m ansible.builtin.shell \
          -a "foreman-maintain service stop; sync; echo 3 > /proc/sys/vm/drop_caches; foreman-maintain service start" \
          satellite6
    fi

    a 00-info-rpm-q-katello.log \
      -m ansible.builtin.shell \
      -a "rpm -q katello" \
      satellite6
    katello_version=$( tail -n 1 $logs/00-info-rpm-q-katello.log ); echo "$katello_version" | grep '^katello-[0-9]\.'   # make sure it was detected correctly

    a 00-info-rpm-q-satellite.log \
      -m ansible.builtin.shell \
      -a "rpm -q satellite || true" \
      satellite6
    satellite_version=$( tail -n 1 $logs/00-info-rpm-q-satellite.log )

    log "katello_version = $katello_version"
    log "satellite_version = $satellite_version"

    a 00-check-hammer-ping.log \
      -m ansible.builtin.shell \
      -a "hammer $hammer_opts ping" \
      satellite6

    unset skip_measurement

    set +e   # Quit "-e" mode as from now on failure is not fatal
}

function get_repo_id() {
    local organization="$1"
    local product="$2"
    local repo="$3"
    local tmp=$( mktemp )
    h_out "--output yaml repository info --organization '$organization' --product '$product' --name '$repo'" >$tmp
    grep '^I[Dd]:' $tmp | cut -d ' ' -f 2
}

function status_data_create() {
    # For every measurement, create new status data file, consult with
    # historical data if test result is PASS or FAIL, upload current result
    # to historical storage (ElasticSearch) and add test result to
    # junit.xml for further analysis.

    debug_log="$2.status_data_create_debug"
    (
    set -x

    [ -z "$PARAM_elasticsearch_host" ] && return 0

    if [ -z "$4" -o -z "$5" ]; then
        echo "WARNING: Either start '$4' or end '$5' timestamps are empty, not going to create status data" >&2
        return 1
    fi

    # Activate tools virtualenv
    source venv/bin/activate

    # Load variables
    sd_section=${SECTION:-default}
    sd_cli="$1"
    sd_log="$2"
    sd_name=$( basename $sd_log .log )   # derive testcase name from log name which is descriptive
    sd_rc="$3"
    sd_start="$( date -u -Iseconds -d @$4 )"
    sd_end="$( date -u -d -Iseconds -d @$5 )"
    sd_duration="$(( $( date -d @$5 +%s ) - $( date -d @$4 +%s ) ))"
    sd_kat_ver="$6"
    sd_kat_ver_short=$( echo "$sd_kat_ver" | sed 's/^katello-//' | sed 's/[^0-9.-]//g' | sed 's/^\([0-9]\+\.[0-9]\+\)\..*/\1/' | sed 's/^N\/A$/0.0/' )   # "katello-3.16.0-0.2.master.el7.noarch" -> "3.16"
    sd_sat_ver="$7"
    if [[ "${sd_sat_ver}" == 'stream' ]]; then
        sd_sat_ver_short=stream
    elif [[ "$(echo "${sd_sat_ver}" | awk -F'.' '{print $(NF-2)}')" == 'stream' ]]; then
        sd_sat_ver_short=stream
    else
        sd_sat_ver_short=$( echo "${sd_sat_ver}" | sed 's/^satellite-//' | sed 's/[^0-9.-]//g' | sed 's/^\([0-9]\+\.[0-9]\+\)\..*/\1/' | sed 's/^N\/A$/0.0/' )   # "satellite-6.6.0-1.el7.noarch" -> "6.6"
    fi
    sd_run="$8"
    sd_additional="$9"
    if [ -n "$STATUS_DATA_FILE" -a -f "$STATUS_DATA_FILE" ]; then
        sd_file=$STATUS_DATA_FILE
    else
        sd_file="$sd_log.json"
        rm -f "$sd_file"
    fi
    if [ -n "${RDD_FILE}" -a -f "${RDD_FILE}" ]; then
        rdd_file=${RDD_FILE}
    else
        rdd_file="${sd_log}.rdd.json"
        rm -f "${rdd_file}"
    fi
    if [ -n "$PARAM_inventory" ]; then
        sd_hostname="$( ansible $opts_adhoc --list-hosts satellite6 2>/dev/null | tail -n 1 | sed -e 's/^\s\+//' -e 's/\s\+$//' )"
    fi
    workdir_url="${PARAM_workdir_url:-https://workdir-exporter.example.com/workspace}"
    sd_link="${workdir_url}/${JOB_NAME:-NA}/${sd_log}"

    # Create status data file
    set -x
    status_data.py --status-data-file $sd_file --set \
      "id=$sd_run" \
      "name=$sd_section/$sd_name" \
      "parameters.cli=$( echo "$sd_cli" | sed 's/=/__/g' )" \
      "parameters.katello_version=$sd_kat_ver" \
      "parameters.katello_version-y-stream=$sd_kat_ver_short" \
      "parameters.version=$sd_sat_ver" \
      "parameters.version-y-stream=$sd_sat_ver_short" \
      "parameters.run=$sd_run" \
      "parameters.hostname=$sd_hostname" \
      "results.log=$sd_log" \
      "results.rc=$sd_rc" \
      "results.duration=$sd_duration" \
      "results.jenkins.build_url=${BUILD_URL:-NA}" \
      "results.jenkins.node_name=${NODE_NAME:-NA}" \
      "started=$sd_start" \
      "ended=$sd_end" \
      "golden=${GOLDEN:-false}" \
      $sd_additional
    set +x

    # Add monitoring data to the status data file
    if [ -n "$PARAM_cluster_read_config" -a -n "$PARAM_grafana_host" ]; then
        set -x
        status_data.py -d --status-data-file $sd_file \
          --additional "$PARAM_cluster_read_config" \
          --monitoring-start "$sd_start" \
          --monitoring-end "$sd_end" \
          --grafana-host "$PARAM_grafana_host" \
          --grafana-port "$PARAM_grafana_port" \
          --grafana-prefix "$PARAM_grafana_prefix" \
          --grafana-datasource "$PARAM_grafana_datasource" \
          --grafana-interface "$PARAM_grafana_interface" \
          --grafana-token "$PARAM_grafana_token" \
          --grafana-node "$PARAM_grafana_node"
        set +x
    fi

    # Based on historical data, determine result of this test
    sd_result_log=$( mktemp )
    if [ "$sd_rc" -eq 0 -a -n "$PARAM_investigator_config" ]; then
        export sd_section
        export sd_name
        set +e
        set -x
        pass_or_fail.py \
          --config "$PARAM_investigator_config" \
          --current-file "$sd_file" 2>&1 | tee $sd_result_log
        pof_rc=$?
        set +x
        set -e
        if [[ $pof_rc -eq 0 ]]; then
            sd_result='PASS'
        elif [[ $pof_rc -eq 1 ]]; then
            sd_result='FAIL'
        else
            sd_result='ERROR'
        fi
    else
        sd_result='ERROR'
    fi

    # Add result to the status data so it is complete
    status_data.py --status-data-file $sd_file --set "result=$sd_result"

    # Upload status data to ElasticSearch
    url="http://$PARAM_elasticsearch_host:$PARAM_elasticsearch_port/${PARAM_elasticsearch_index:-satellite_perf_index}/${PARAM_elasticsearch_mapping:-_doc}/"
    echo "INFO: POSTing '$sd_file' to '$url'"
    curl --silent \
      -X POST \
      -H "Content-Type: application/json" \
      --data "@$sd_file" \
      "$url" |
      python -c "import sys, json; obj, pos = json.JSONDecoder().raw_decode(sys.stdin.read()); assert '_shards' in obj and  obj['_shards']['successful'] >= 1 and obj['_shards']['failed'] == 0, 'Failed to upload status data: %s' % obj"
    ###status_data.py --status-data-file $sd_file --info

    # Create "results-dashboard-data" data file
    set -x
    jq -n \
      --arg version ${sd_sat_ver} \
      --arg release ${sd_sat_ver_short} \
      --arg date ${sd_start} \
      --arg link ${sd_link} \
      --arg result_id ${marker_date} \
      --arg test ${sd_name} \
      --arg result ${sd_result} \
      '{
        "group": "Core Platforms",
        "product": "Red Hat Satellite",
        "version": $version,
        "release": $release,
        "date": $date,
        "link": $link,
        "result_id": $result_id,
        "test": $test,
        "result": $result,
      }' >${rdd_file}
    set +x

    # Upload status data to "results-dashboard-data" ElasticSearch
    url="http://${PARAM_elasticsearch_host}:${PARAM_elasticsearch_port}/results-dashboard-data/${PARAM_elasticsearch_mapping:-_doc}/"
    echo "INFO: POSTing results data to '$url'"
    curl --silent \
      -X POST \
      -H "Content-Type: application/json" \
      --data "@${rdd_file}" \
      "$url" |
      python -c "import sys, json; obj, pos = json.JSONDecoder().raw_decode(sys.stdin.read()); assert '_shards' in obj and  obj['_shards']['successful'] >= 1 and obj['_shards']['failed'] == 0, 'Failed to upload status data: %s' % obj"

    # Enhance log file
    tmp=$( mktemp )
    echo "command: $sd_cli" >>$tmp
    echo "satellite version: $sd_sat_ver" >>$tmp
    echo "katello version: $sd_kat_ver" >>$tmp
    echo "hostname: $sd_hostname" >>$tmp
    if [ "$sd_result" != 'ERROR' ]; then
        echo "result determination log:" >>$tmp
        cat "$sd_result_log" >>$tmp
    fi
    echo "" >>$tmp
    cat "$sd_log" >>$tmp

    # Create junit.xml file
    junit_cli.py --file $logs/junit.xml add --suite "$sd_section" \
      --name "$sd_name" --result "$sd_result" --out "$tmp" \
      --start "$sd_start" --end "$sd_end"

    # Deactivate tools virtualenv
    deactivate

    set +x
    ) &>$debug_log
}

function junit_upload() {
    # Upload junit.xml into ReportPortal for test result investigation

    # Make the file available for Jenkins on the same path every time
    cp "$logs/junit.xml" latest-junit.xml

    [ -z "$PARAM_reportportal_host" ] && return 0

    # Activate tools virtualenv
    source venv/bin/activate

    # Determine ReportPortal launch name
    launch_name="${PARAM_reportportal_launch_name:-default-launch-name}"
    if echo "$launch_name" | grep --quiet '%sat_ver%'; then
        sat_ver="$( echo "$satellite_version" | sed 's/^satellite-//' | sed 's/^\([0-9]\+\.[0-9]\+\).*/\1/' )"
        [ -z "$sat_ver" ] && sat_ver="$( echo "$katello_version" | sed 's/^katello-//' | sed 's/^\([0-9]\+\.[0-9]\+\).*/\1/' )"
        launch_name="$( echo "$launch_name" | sed "s/%sat_ver%/$sat_ver/g" )"
    fi
    launch_name="$( echo "$launch_name" | sed "s/[^a-zA-Z0-9._-]/_/g" )"

    # Show content and upload to ReportPortal
    junit_cli.py --file $logs/junit.xml print
    junit_cli.py --file $logs/junit.xml upload \
      --host $PARAM_reportportal_host \
      --project $PARAM_reportportal_project \
      --token $PARAM_reportportal_token \
      --launch $launch_name \
      --noverify \
      --properties jenkins_build_url=$BUILD_URL run_id=$marker

    # Deactivate tools virtualenv
    deactivate
}

function log() {
    echo "[$( date -u -Iseconds )] $*"
}

function section() {
    name="${1:-default}"
    label="$( echo "$name" | sed 's/[^a-zA-Z0-9_-]/_/g' | sed 's/_\+/_/g' )"
    log "===== $name ====="
    export SECTION="$label"
}

function _format_opts() {
    out=""
    while [ -n "$1" ]; do
        if echo "$1" | grep --quiet ' '; then
            out_add="\"$1\""
        else
            out_add="$1"
        fi
        out="$out $out_add"
        shift
    done
    echo "$out"
}

function c() {
    local out=$logs/$1; shift
    mkdir -p $( dirname $out )
    local start=$( date -u +%s )
    log "Start '$*' with log in $out"
    if $run_lib_dryrun; then
        log "FAKE command RUN"
        local rc=0
    else
        eval "$@" &>$out && local rc=$? || local rc=$?
    fi
    local end=$( date -u +%s )
    log "Finish after $(( $end - $start )) seconds with log in $out and exit code $rc"
    measurement_add \
      "$@" \
      "$out" \
      "$rc" \
      "$start" \
      "$end" \
      "$katello_version" \
      "$satellite_version" \
      "$marker"
    return $rc
}

function a() {
    local out=$logs/$1; shift
    mkdir -p $( dirname $out )
    local start=$( date -u +%s )
    log "Start 'ansible $opts_adhoc $*' with log in $out"
    if $run_lib_dryrun; then
        log "FAKE ansible RUN"
        local rc=0
    else
        ansible $opts_adhoc "$@" &>$out && local rc=$? || local rc=$?
    fi
    local end=$( date -u +%s )
    log "Finish after $(( $end - $start )) seconds with log in $out and exit code $rc"
    measurement_add \
      "ansible $opts_adhoc $( _format_opts "$@" )" \
      "$out" \
      "$rc" \
      "$start" \
      "$end" \
      "$katello_version" \
      "$satellite_version" \
      "$marker"
    return $rc
}

function a_out() {
    # Just run the ansible command. No output processing, action logging or measurements
    if $run_lib_dryrun; then
        echo "FAKE ansible RUN"
    else
        ansible $opts_adhoc "$@"
    fi
}

function ap() {
    local out=$logs/$1; shift
    mkdir -p $( dirname $out )
    local start=$( date -u +%s )
    log "Start 'ansible-playbook $opts_adhoc $*' with log in $out"
    if $run_lib_dryrun; then
        log "FAKE ansible-playbook RUN"
        local rc=0
    else
        ansible-playbook $opts_adhoc "$@" &>$out && local rc=$? || local rc=$?
    fi
    local end=$( date -u +%s )
    log "Finish after $(( $end - $start )) seconds with log in $out and exit code $rc"
    measurement_add \
      "ansible-playbook $opts_adhoc $( _format_opts "$@" )" \
      "$out" \
      "$rc" \
      "$start" \
      "$end" \
      "$katello_version" \
      "$satellite_version" \
      "$marker"
    return $rc
}

function s() {
    log "Sleep for $1 seconds"
    if $run_lib_dryrun; then
        log "FAKE SLEEP"
    else
        sleep $1
    fi
}

function h() {
    local log_relative=$1; shift
    a "$log_relative" \
      -m ansible.builtin.shell \
      -a "hammer $hammer_opts $@" \
      satellite6
}

function h_drop() {
    # Run hammer command as usual, but drop its stdout
    local log_relative=$1; shift
    a "$log_relative" \
      -m ansible.builtin.shell \
      -a "hammer $hammer_opts $@ >/dev/null" \
      satellite6
}

function h_out() {
    # Just run the hammer command via ansible. No output processing, action logging or measurements
    a_out \
      -m ansible.builtin.shell \
      -a "hammer $hammer_opts $@" \
      satellite6
}

function e() {
    # Examine log for specific measure using reg-average.py
    local grepper="$1"
    local log="$2"
    local log_report="$( echo "$log" | sed "s/\.log$/-$grepper.log/" )"
    experiment/reg-average.py "$grepper" "$log" &>$log_report
    local rc=$?
    local started_ts=$( grep "^min in" $log_report | tail -n 1 | cut -d ' ' -f 4 )
    local ended_ts=$( grep "^max in" $log_report | tail -n 1 | cut -d ' ' -f 4 )
    local duration=$( grep "^$grepper" $log_report | tail -n 1 | cut -d ' ' -f 4 )
    local passed=$( grep "^$grepper" $log_report | tail -n 1 | cut -d ' ' -f 6 )
    local avg_duration=$( grep "^$grepper" $log_report | tail -n 1 | cut -d ' ' -f 8 )
    log "Examined $log for $grepper: $duration / $passed = $avg_duration (ranging from $started_ts to $ended_ts)"
    measurement_add \
      "experiment/reg-average.py '$grepper' '$log'" \
      "$log_report" \
      "$rc" \
      "$started_ts" \
      "$ended_ts" \
      "$katello_version" \
      "$satellite_version" \
      "$marker" \
      "results.items.duration=$duration results.items.passed=$passed results.items.avg_duration=$avg_duration results.items.report_rc=$rc"
}

function task_examine() {
    # Show task duration without outliners
    local log="$1"
    local task_id="$2"
    [ -z "$task_id" ] && return 1
    local command="${3:-N/A}"
    local satellite_host="$( ansible $opts_adhoc --list-hosts satellite6 2>/dev/null | tail -n 1 | sed -e 's/^\s\+//' -e 's/\s\+$//' )"
    [ -z "$satellite_host" ] && return 2
    local log_report="$( echo "$log" | sed "s/\.log$/-duration.log/" )"

    scripts/get-task-fuzzy-duration.py \
      --hostname $satellite_host \
      --task-id "$task_id" \
      --timeout 150 \
      --percentage 5 \
      --output status-data \
      &>$log_report
    local rc=$?
    if (( rc == 0 )); then
        started_ts="$( date -d "$( grep '^results.tasks.start=' $log_report | cut -d '"' -f 2 )" +%s )"
        ended_ts="$( date -d "$( grep '^results.tasks.end=' $log_report | cut -d '"' -f 2 )" +%s )"
        duration="$( grep '^results.tasks.duration=' $log_report | cut -d '"' -f 2 )"
        head_tail_perc="$( grep '^results.tasks.percentage_removed=' $log_report | cut -d '"' -f 2 )"
        log "Examined task $task_id and it has $head_tail_perc % of head/tail (ranging from $started_ts to $ended_ts) and has taken $duration seconds"
        measurement_add \
          "$command" \
          "$log_report" \
          "$rc" \
          "$started_ts" \
          "$ended_ts" \
          "$katello_version" \
          "$satellite_version" \
          "$marker" \
          "$( grep '^results.tasks.[a-zA-Z0-9_]*="[^"]*"$' $log_report )"
        return 0
    else
        log "There were errors examining the task $task_id. Please check $log and $log_report log files"
    fi
    return 1
}

function t() {
    # Parse task ID from the log and examine the task
    local log="$1"
    local task_id="$( extract_task "$log" )"
    [ -z "$task_id" ] && return 1

    task_examine "$log" $task_id "Investigating task $task_id"
}

function j() {
    # Parse job invocation ID from the log, get parent task ID and examine it
    local log="$1"
    local job_invocation_id="$( extract_job_invocation "$log" )"
    [ -z "$job_invocation_id" ] && return 1
    local satellite_host="$( ansible $opts_adhoc \
      --list-hosts \
      satellite6 2>/dev/null |
      tail -n 1 | sed -e 's/^\s\+//' -e 's/\s\+$//' )"
    [ -z "$satellite_host" ] && return 2
    local satellite_creds="$( ansible $opts_adhoc \
      -m ansible.builtin.debug \
      -a "msg={{ sat_user }}:{{ sat_pass }}" \
      satellite6 2>/dev/null |
      grep '"msg":' | cut -d '"' -f 4)"
    [ -z "$satellite_creds" ] && return 2
    local task_id=$( curl --silent --insecure \
      -u "$satellite_creds" \
      -X GET \
      -H 'Accept: application/json' \
      -H 'Content-Type: application/json' \
      --max-time 30 \
      https://$satellite_host/api/job_invocations?search=id=${job_invocation_id} |
      python3 -c 'import json, sys; print(json.load(sys.stdin)["results"][0]["dynflow_task"]["id"])' )

    task_examine "$log" $task_id "Investigating job invocation $job_invocation_id (task $task_id)"
}

function jsr() {
    # Parse job invocation ID from the log and show its execution success ratio
    local log="$1"
    local job_invocation_id="$( extract_job_invocation "$log" )"
    [ -z "${job_invocation_id}" ] && return 1
    local satellite_host="$( ansible $opts_adhoc \
      --list-hosts \
      satellite6 2>/dev/null |
      tail -n 1 | sed -e 's/^\s\+//' -e 's/\s\+$//' )"
    [ -z "${satellite_host}" ] && return 2
    local satellite_creds="$( ansible $opts_adhoc \
      -m ansible.builtin.debug \
      -a "msg={{ sat_user }}:{{ sat_pass }}" \
      satellite6 2>/dev/null |
      grep '"msg":' | cut -d '"' -f 4 )"
    [ -z "${satellite_creds}" ] && return 2

    local min_minutes_counter=5
    local max_minutes_counter=300
    local divisor=50

    local task_state="$( curl --silent --insecure \
      -u "${satellite_creds}" \
      -X GET \
      -H 'Accept: application/json' \
      -H 'Content-Type: application/json' \
      --max-time 30 \
      https://${satellite_host}/api/job_invocations?search=id=${job_invocation_id} |
      python3 -c 'import json, sys; print(json.load(sys.stdin)["results"][0]["dynflow_task"]["state"])' )"

    local total_tasks="$( curl --silent --insecure \
      -u "${satellite_creds}" \
      -X GET \
      -H 'Accept: application/json' \
      -H 'Content-Type: application/json' \
      --max-time 30 \
      https://${satellite_host}/api/job_invocations?search=id=${job_invocation_id} |
      python3 -c 'import json, sys; print(json.load(sys.stdin)["results"][0]["total"])' )"
    local ratio="$(( total_tasks / divisor ))"

    if (( ratio < min_minutes_counter )); then
        max_minutes_counter=$min_minutes_counter
    elif (( ratio < max_minutes_counter )); then
        max_minutes_counter=$ratio
    fi

    local minutes_counter=0
    local sleep_time=60
    local rc=0
    while [[ "${task_state}" != 'stopped' ]]; do
        if (( minutes_counter < max_minutes_counter )); then
            sleep ${sleep_time}

            task_state="$( curl --silent --insecure \
              -u "${satellite_creds}" \
              -X GET \
              -H 'Accept: application/json' \
              -H 'Content-Type: application/json' \
              --max-time 30 \
              https://${satellite_host}/api/job_invocations?search=id=${job_invocation_id} |
              python3 -c 'import json, sys; print(json.load(sys.stdin)["results"][0]["dynflow_task"]["state"])' )"

            (( minutes_counter++ ))
        else
            rc=1

            log "Ran out of time waiting for job invocation ${job_invocation_id} to finish. Trying to cancel it..."

            curl --silent --insecure \
              -u "${satellite_creds}" \
              -X POST \
              -H 'Accept: application/json' \
              -H 'Content-Type: application/json' \
              --max-time 30 \
              "https://${satellite_host}/api/job_invocations/${job_invocation_id}/cancel?force=true" &>/dev/null

            # Wait for 10 additional minutes for the job invocation to cancel
            minutes_counter=0
            while [[ "${task_state}" != 'stopped' ]]; do
                if (( minutes_counter < max_minutes_counter )); then
                    sleep ${sleep_time}

                    task_state="$( curl --silent --insecure \
                      -u "${satellite_creds}" \
                      -X GET \
                      -H 'Accept: application/json' \
                      -H 'Content-Type: application/json' \
                      --max-time 30 \
                      https://${satellite_host}/api/job_invocations?search=id=${job_invocation_id} |
                      python3 -c 'import json, sys; print(json.load(sys.stdin)["results"][0]["dynflow_task"]["state"])' )"

                    (( minutes_counter++ ))
                else
                    break
                fi
            done

            break
        fi
    done

    local succeeded="$( curl --silent --insecure \
      -u "${satellite_creds}" \
      -X GET \
      -H 'Accept: application/json' \
      -H 'Content-Type: application/json' \
      --max-time 30 \
      https://${satellite_host}/api/job_invocations?search=id=${job_invocation_id} |
      python3 -c 'import json, sys; print(json.load(sys.stdin)["results"][0]["succeeded"])' )"
    local total="$( curl --silent --insecure \
      -u "${satellite_creds}" \
      -X GET \
      -H 'Accept: application/json' \
      -H 'Content-Type: application/json' \
      --max-time 30 \
      https://${satellite_host}/api/job_invocations?search=id=${job_invocation_id} |
      python3 -c 'import json, sys; print(json.load(sys.stdin)["results"][0]["total"])' )"

    log "Examined job invocation $job_invocation_id: $succeeded / $total successful executions"

    return $rc
}

function extract_task() {
    # Take log with hammer run log and extract task ID from it. Do not return
    # anything if more task IDs are found or in case of any other error.
    log="$1"
    candidates=$( grep '^Task [0-9a-zA-Z-]\+ running' "$log" | cut -d ' ' -f 2 | uniq )
    # Only print f we have exactly one task ID
    if [ $( echo "$candidates" | wc -l | cut -d ' ' -f 1 ) -eq 1 ]; then
        echo "$candidates"
        return 0
    fi
    return 1
}

function extract_job_invocation() {
    # Take log with hammer job-invocation create --async output and extract
    # job invocation ID from it. Do not return anything if more IDs are found
    # or in case of any other error.
    log=$1
    candidates=$( grep '^Job invocation [0-9]\+ created' "$log" | cut -d ' ' -f 3 | uniq )
    # Only print if we have exactly one job invocation ID
    if [ $( echo "$candidates" | wc -l | cut -d ' ' -f 1 ) -eq 1 ]; then
        echo "$candidates"
        return 0
    fi
    return 1
}

function table_row() {
    # Format row for results table with average duration
    local identifier="/$( echo "$1" | sed 's/\./\./g' ),"
    local description="$2"
    local grepper="$3"
    export IFS=$'\n'
    local count=0
    local sum=0
    local note=""
    for row in $( grep "$identifier" $logs/measurement.log ); do
        local rc="$( echo "$row" | measurement_row_field 3 )"
        if [ "$rc" -ne 0 ]; then
            echo "ERROR: Row '$row' have non-zero return code. Not considering it when counting duration :-(" >&2
            continue
        fi
        if [ -n "$grepper" ]; then
            local log="$( echo "$row" | measurement_row_field 2 )"
            local out=$( experiment/reg-average.py "$grepper" "$log" 2>/dev/null | grep "^$grepper in " | tail -n 1 )
            local passed=$( echo "$out" | cut -d ' ' -f 6 )
            [ -z "$note" ] && note="Number of passed:"
            local note="$note $passed"
            local diff=$( echo "$out" | cut -d ' ' -f 8 )
            if [ -n "$diff" ]; then
                sum=$( echo "$sum + $diff" | bc )
                let count+=1
            fi
        else
            local start="$( echo "$row" | measurement_row_field 4 )"
            local end="$( echo "$row" | measurement_row_field 5 )"
            sum=$( echo "$sum + $end - $start" | bc )
            let count+=1
        fi
    done
    if [ "$count" -eq 0 ]; then
        local avg="N/A"
    else
        local avg=$( echo "scale=2; $sum / $count" | bc )
    fi
    echo -e "$description\t$avg\t$note"
}


# Create dir for logs
mkdir -p "$logs/"
log "Logging into '$logs/' directory"
