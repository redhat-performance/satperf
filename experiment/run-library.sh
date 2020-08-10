#!/bin/bash

set -o pipefail
###set -x
# Disable `set -e` for today (see `date -d @1594369339` for timestamp interpretation)
[ "$( date +%s )" -gt 1594369339 ] && set -e


# We need to add an ID to run-bench runs to be able to filter out results from multiple runs. This ID will be appended as
# the last field of lines in measurement.log file.
# The ID should be passed as a argument to the run-bench.sh. If there is no argument passed, default ID will be
# generated based on the current date and time.
if [ -z "$marker" ]; then
    marker=${1:-run-$(date --utc --iso-8601=seconds)}
fi

opts=${opts:-"--forks 100 -i conf/20170625-gprfc019.ini"}
opts_adhoc=${opts_adhoc:-"$opts --user root -e @conf/satperf.yaml -e @conf/satperf.local.yaml"}
logs="$marker"
run_lib_dryrun=false
hammer_opts="-u admin -p changeme"
satellite_version="${satellite_version:-N/A}"   # will be determined automatically by run-bench.sh
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

function _vercmp() {
    # FIXME: This parser sucks. Would be better to have rpmdev-vercmp once
    # CID-5112 is resolved
    ver1=$( echo "$1" | sed 's/^\(satellite\|katello\)-//' | sed 's/^\([^-]\+\)-.*$/\1/' )
    ver2=$( echo "$2" | sed 's/^\(satellite\|katello\)-//' | sed 's/^\([^-]\+\)-.*$/\1/' )
    echo "Comparing $ver1 vs. $ver2"
    ver1_1=$( echo "$ver1" | cut -d '.' -f 1 )
    ver1_2=$( echo "$ver1" | cut -d '.' -f 2 )
    ver1_3=$( echo "$ver1" | cut -d '.' -f 3 )
    ver2_1=$( echo "$ver2" | cut -d '.' -f 1 )
    ver2_2=$( echo "$ver2" | cut -d '.' -f 2 )
    ver2_3=$( echo "$ver2" | cut -d '.' -f 3 )
    vers1=( $ver1_1 $ver1_2 $ver1_3 )
    vers2=( $ver2_1 $ver2_2 $ver2_3 )
    for i in 0 1 2; do
        echo "Comparing item ${vers1[$i]} vs. ${vers2[$i]}"
        if [ "${vers1[$i]}" -gt "${vers2[$i]}" ]; then
            return 11
        elif [ "${vers1[$i]}" -lt "${vers2[$i]}" ]; then
            return 12
        fi
    done
    return 0
}

function vercmp_gt() {
    # Check if first parameter is greater than second using version string comparision
    _vercmp "$1" "$2"
    local rc=$?
    [ "$rc" -eq 11 ] && return 0 || return 1
}

function vercmp_ge() {
    # Check if first parameter is greater or equal than second using version string comparision
    _vercmp "$1" "$2"
    local rc=$?
    [ "$rc" -eq 11 -o "$rc" -eq 0 ] && return 0 || return 1
}

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
    skip_measurement='true' a 00-info-rpm-qa.log satellite6 -m "shell" -a "rpm -qa | sort"
    skip_measurement='true' a 00-info-hostname.log satellite6 -m "shell" -a "hostname"
    skip_measurement='true' a 00-info-ip-a.log satellite6,docker-hosts -m "shell" -a "ip a"
    skip_measurement='true' a 00-check-ping-sat.log docker-hosts -m "shell" -a "ping -c 3 {{ groups['satellite6']|first }}"
    skip_measurement='true' a 00-check-hammer-ping.log satellite6 -m "shell" -a "! ( hammer $hammer_opts ping | grep 'Status:' | grep -v 'ok$' )"

    if $extended; then
        skip_measurement='true' ap 00-recreate-containers.log playbooks/docker/docker-tierdown.yaml playbooks/docker/docker-tierup.yaml
        skip_measurement='true' ap 00-recreate-client-scripts.log playbooks/satellite/client-scripts.yaml
        skip_measurement='true' ap 00-remove-hosts-if-any.log playbooks/satellite/satellite-remove-hosts.yaml
    fi

    skip_measurement='true' a 00-satellite-drop-caches.log -m shell -a "foreman-maintain service stop; sync; echo 3 > /proc/sys/vm/drop_caches; foreman-maintain service start" satellite6

    skip_measurement='true' a 00-info-rpm-q-katello.log satellite6 -m "shell" -a "rpm -q katello"
    katello_version=$( tail -n 1 $logs/00-info-rpm-q-katello.log ); echo "$katello_version" | grep '^katello-[0-9]\.'   # make sure it was detected correctly
    skip_measurement='true' a 00-info-rpm-q-satellite.log satellite6 -m "shell" -a "rpm -q satellite || true"
    satellite_version=$( tail -n 1 $logs/00-info-rpm-q-satellite.log )
    log "katello_version = $katello_version"
    log "satellite_version = $satellite_version"

    set +e   # Quit "-e" mode as from now on failure is not fatal
    s $( expr 3 \* $wait_interval )
}

function get_repo_id() {
    local tmp=$( mktemp )
    local product="$1"
    local repo="$2"
    h_out "--output yaml repository info --organization '$do' --product '$product' --name '$repo'" >$tmp
    grep '^ID:' $tmp | cut -d ' ' -f 2
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
    source insights-perf/venv/bin/activate

    # Load variables
    sd_section=${SECTION:-default}
    sd_cli="$1"
    sd_log="$2"
    sd_name=$( basename $sd_log .log )   # derive testcase name from log name which is descriptive
    sd_rc="$3"
    sd_start="$( date --utc -d @$4 -Iseconds )"
    sd_end="$( date --utc -d @$5 -Iseconds )"
    sd_duration="$( expr $5 - $4 )"
    sd_kat_ver="$6"
    sd_kat_ver_short=$( echo "$sd_kat_ver" | sed 's/^katello-//' | sed 's/[^0-9.]//g' | sed 's/^\([0-9]\+\.[0-9]\+\)\..*/\1/' | sed 's/^N\/A$/0.0/' )   # "katello-3.16.0-0.2.master.el7.noarch" -> "3.16"
    sd_sat_ver="$7"
    sd_sat_ver_short=$( echo "$sd_sat_ver" | sed 's/^satellite-//' | sed 's/[^0-9.]//g' | sed 's/^\([0-9]\+\.[0-9]\+\)\..*/\1/' | sed 's/^N\/A$/0.0/' )   # "satellite-6.6.0-1.el7.noarch" -> "6.6"
    sd_run="$8"
    sd_file="$sd_log.json"
    sd_additional="$9"
    if [ -n "$PARAM_inventory" ]; then
        sd_hostname="$( ansible -i "$PARAM_inventory" --list-hosts satellite6 2>/dev/null | tail -n 1 | sed -e 's/^\s\+//' -e 's/\s\+$//' )"
    fi

    # Create status data file
    rm -f "$sd_file"
    insights-perf/status_data.py --status-data-file $sd_file --set \
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
        $sd_additional

    # Add monitoring data to the status data file
    if [ -n "$PARAM_cluster_read_config" -a -n "$PARAM_grafana_host" ]; then
        insights-perf/status_data.py -d --status-data-file $sd_file \
            --additional "$PARAM_cluster_read_config" \
            --monitoring-start "$sd_start" --monitoring-end "$sd_end" \
            --grafana-host "$PARAM_grafana_host" \
            --grafana-port "$PARAM_grafana_port" \
            --grafana-prefix "$PARAM_grafana_prefix" \
            --grafana-datasource "$PARAM_grafana_datasource" \
            --grafana-interface "$PARAM_grafana_interface" \
            --grafana-token "$PARAM_grafana_token" \
            --grafana-node "$PARAM_grafana_node"
    fi

    # Based on historical data, determine result of this test
    sd_result_log=$( mktemp )
    if [ "$sd_rc" -eq 0 ]; then
        # FIXME: Once we have bunch of runs with parameters.version-y-stream, we can stop using `--data-from-es-wildcard "parameters.version=*$sd_sat_ver_short*"` here and just use new variable
        insights-perf/data_investigator.py --data-from-es \
            --data-from-es-matcher "results.rc=0" "name=$sd_name" \
            --data-from-es-wildcard "parameters.version=*$sd_sat_ver_short*" \
            --es-host $PARAM_elasticsearch_host \
            --es-port $PARAM_elasticsearch_port \
            --es-index satellite_perf_index \
            --es-type cpt \
            --test-from-status "$sd_file" &>$sd_result_log \
            && di_rc=$? || di_rc=$?
        if [ "$di_rc" -eq 0 ]; then
            sd_result='PASS'
        else
            sd_result='FAIL'
        fi
    else
        sd_result='ERROR'
    fi

    # Add result to the status data so it is complete
    insights-perf/status_data.py --status-data-file $sd_file --set "result=$sd_result"

    # Upload status data to ElasticSearch
    curl --silent -H "Content-Type: application/json" -X POST \
        "http://$PARAM_elasticsearch_host:$PARAM_elasticsearch_port/satellite_perf_index/cpt/" \
        --data "@$sd_file" \
            | python -c "import sys, json; obj, pos = json.JSONDecoder().raw_decode(sys.stdin.read()); assert '_shards' in obj and  obj['_shards']['successful'] == 1 and obj['_shards']['failed'] == 0, 'Failed to upload status data: %s' % obj"
    ###insights-perf/status_data.py --status-data-file $sd_file --info

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
    insights-perf/junit_cli.py --file $logs/junit.xml add --suite "$sd_section" \
        --name "$sd_name" --result "$sd_result" --out "$tmp" \
        --start "$sd_start" --end "$sd_end"
    ###insights-perf/junit_cli.py --file $logs/junit.xml print

    # Deactivate tools virtualenv
    deactivate

    set +x
    ) &>$debug_log
}

function junit_upload() {
    # Upload junit.xml into ReportPortal for test result investigation

    [ -z "$PARAM_reportportal_host" ] && return 0

    # Determine ReportPortal launch name
    launch_name="${PARAM_reportportal_launch_name:-default-launch-name}"
    if echo "$launch_name" | grep --quiet '%sat_ver%'; then
        sat_ver="$( echo "$satellite_version" | sed 's/^satellite-//' | sed 's/^\([0-9]\+\.[0-9]\+\).*/\1/' )"
        [ -z "$sat_ver" ] && sat_ver="$( echo "$katello_version" | sed 's/^katello-//' | sed 's/^\([0-9]\+\.[0-9]\+\).*/\1/' )"
        launch_name="$( echo "$launch_name" | sed "s/%sat_ver%/$sat_ver/g" )"
    fi
    launch_name="$( echo "$launch_name" | sed "s/[^a-zA-Z0-9._-]/_/g" )"

    # Create and upload zip to ReportPortal
    zip_name="$launch_name.zip"
    rm -f $zip_name
    zip --quiet "$zip_name" "$logs/junit.xml"
    curl --silent --insecure -X POST --header 'Accept: application/json' \
        --header "Authorization: bearer $PARAM_reportportal_token" \
        --form "file=@$zip_name" \
        "https://$PARAM_reportportal_host/api/v1/$PARAM_reportportal_project/launch/import" \
            | grep --quiet 'Launch with id = [0-9a-f]\+ is successfully imported' \
                || echo "Failed to upload junit" >&2
    rm -f "$zip_name"
    cp "$logs/junit.xml" latest-junit.xml   # so Jenkins can find it easilly on the same path every time
}

function log() {
    echo "[$( date --utc --iso-8601=seconds )] $*"
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
    local start=$( date --utc +%s )
    log "Start '$*' with log in $out"
    if $run_lib_dryrun; then
        log "FAKE command RUN"
        local rc=0
    else
        eval "$@" &>$out && local rc=$? || local rc=$?
    fi
    local end=$( date --utc +%s )
    log "Finish after $( expr $end - $start ) seconds with log in $out and exit code $rc"
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
    local start=$( date --utc +%s )
    log "Start 'ansible $opts_adhoc $*' with log in $out"
    if $run_lib_dryrun; then
        log "FAKE ansible RUN"
        local rc=0
    else
        ansible $opts_adhoc "$@" &>$out && local rc=$? || local rc=$?
    fi
    local end=$( date --utc +%s )
    log "Finish after $( expr $end - $start ) seconds with log in $out and exit code $rc"
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
    local start=$( date --utc +%s )
    log "Start 'ansible-playbook $opts $*' with log in $out"
    if $run_lib_dryrun; then
        log "FAKE ansible-playbook RUN"
        local rc=0
    else
        ansible-playbook $opts "$@" &>$out && local rc=$? || local rc=$?
    fi
    local end=$( date --utc +%s )
    log "Finish after $( expr $end - $start ) seconds with log in $out and exit code $rc"
    measurement_add \
        "ansible-playbook $opts $( _format_opts "$@" )" \
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
    a "$log_relative" -m shell -a "hammer $hammer_opts $@" satellite6
}

function h_out() {
    # Just run the hammer command via ansible. No output processing, action logging or measurements
    a_out -m shell -a "hammer $hammer_opts $@" satellite6
}

function e() {
    # Examine log for specific measure using reg-average.sh
    local grepper="$1"
    local log="$2"
    local log_report="$( echo "$log" | sed "s/\.log$/-$grepper.log/" )"
    experiment/reg-average.sh "$grepper" "$log" &>$log_report
    local rc=$?
    local started_ts=$( grep "^min in" $log_report | tail -n 1 | cut -d ' ' -f 4 )
    local ended_ts=$( grep "^max in" $log_report | tail -n 1 | cut -d ' ' -f 4 )
    local duration=$( grep "^$grepper" $log_report | tail -n 1 | cut -d ' ' -f 4 )
    local passed=$( grep "^$grepper" $log_report | tail -n 1 | cut -d ' ' -f 6 )
    local avg_duration=$( grep "^$grepper" $log_report | tail -n 1 | cut -d ' ' -f 8 )
    log "Examined $log for $grepper: $duration / $passed = $avg_duration (ranging from $started_ts to $ended_ts)"
    measurement_add \
        "experiment/reg-average.sh '$grepper' '$log'" \
        "$log_report" \
        "$rc" \
        "$started_ts" \
        "$ended_ts" \
        "$katello_version" \
        "$satellite_version" \
        "$marker" \
        "results.items.duration=$duration results.items.passed=$passed results.items.avg_duration=$avg_duration results.items.report_rc=$rc"
}

function t() {
    # Show task duration without outliners
    local log="$1"
    local task_id="$( extract_task "$log" )"
    [ -z "$task_id" ] && return 1
    local satellite_host="$( ansible -i "$PARAM_inventory" --list-hosts satellite6 2>/dev/null | tail -n 1 | sed -e 's/^\s\+//' -e 's/\s\+$//' )"
    [ -z "$satellite_host" ] && return 2
    local log_report="$( echo "$log" | sed "s/\.log$/-duration.log/" )"

    scripts/get-task-fuzzy-duration.py --hostname $satellite_host --task-id "$task_id" --percentage 5 --output status-data &>$log_report
    local rc=$?
    started_ts="$( date -d "$( grep '^results.tasks.start=' $log_report | cut -d '"' -f 2 )" +%s )"
    ended_ts="$( date -d "$( grep '^results.tasks.end=' $log_report | cut -d '"' -f 2 )" +%s )"
    head_tail_perc="$( grep '^results.tasks.percentage_removed=' $log_report | cut -d '"' -f 2 )"
    log "Examined task $task_id and if have $head_tail_perc % of head/tail (ranging from $started_ts to $ended_ts)"
    measurement_add \
        "experiment/reg-average.sh '$grepper' '$log'" \
        "$log_report" \
        "$rc" \
        "$started_ts" \
        "$ended_ts" \
        "$katello_version" \
        "$satellite_version" \
        "$marker" \
        "$( grep '^results.tasks.[a-zA-Z0-9_]*="[^"]*"$' $log_report )"
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
            local out=$( experiment/reg-average.sh "$grepper" "$log" 2>/dev/null | grep "^$grepper in " | tail -n 1 )
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
