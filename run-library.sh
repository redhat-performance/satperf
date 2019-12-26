#!/bin/bash

set -o pipefail
###set -x
set -e


# We need to add an ID to run-bench runs to be able to filter out results from multiple runs. This ID will be appended as
# the last field of lines in measurement.log file.
# The ID should be passed as a argument to the run-bench.sh. If there is no argument passed, default ID will be
# generated based on the current date and time.
if [ -z "$marker" ]; then
    marker=${1:-run-$(date --utc --iso-8601=seconds)}
fi

opts=${opts:-"--forks 100 -i conf/20170625-gprfc019.ini"}
opts_adhoc=${opts_adhoc:-"$opts --user root"}
logs="$marker"
run_lib_dryrun=false
hammer_opts="-u admin -p changeme"
satellite_version="${satellite_version:-N/A}"   # will be determined automatically by run-bench.sh

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
    ver1=$( echo "$1" | sed 's/^satellite-//' | sed 's/^\([^-]\+\)-.*$/\1/' )
    ver2=$( echo "$2" | sed 's/^satellite-//' | sed 's/^\([^-]\+\)-.*$/\1/' )
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
    rc=$?
    [ "$rc" -eq 11 ] && return 0 || return 1
}

function vercmp_ge() {
    # Check if first parameter is greater or equal than second using version string comparision
    _vercmp "$1" "$2"
    rc=$?
    [ "$rc" -eq 11 -o "$rc" -eq 0 ] && return 0 || return 1
}

function measurement_add() {
    python -c "import csv; import sys; fp=open('$logs/measurement.log','a'); writer=csv.writer(fp); writer.writerow(sys.argv[1:]); fp.close()" "$@"
    status_data_create "$@"
}
function measurement_row_field() {
    python -c "import csv; import sys; reader=csv.reader(sys.stdin); print list(reader)[0][int(sys.argv[1])-1]" $1
}

function status_data_create() {
    # For every measurement, create new status data file, consult with
    # historical data if test result is PASS or FAIL, upload current result
    # to historical storage (ElasticSearch) and add test result to
    # junit.xml for further analysis.

    [ -z "$PARAM_elasticsearch_host" ] && return 0

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
    sd_ver="$6"
    sd_ver_short=$( echo "$sd_ver" | sed 's/^satellite-//' | sed 's/^\([0-9]\+\.[0-9]\+\)\..*/\1/' )   # "satellite-6.6.0-1.el7.noarch" -> "6.6"
    sd_run="$7"
    sd_file=$( mktemp )

    ## Show variables
    #log "DEBUG: sd_section = $sd_section"
    #log "DEBUG: sd_cli = $sd_cli"
    #log "DEBUG: sd_log = $sd_log"
    #log "DEBUG: sd_name = $sd_name"
    #log "DEBUG: sd_rc = $sd_rc"
    #log "DEBUG: sd_start = $sd_start"
    #log "DEBUG: sd_end = $sd_end"
    #log "DEBUG: sd_duration = $sd_duration"
    #log "DEBUG: sd_ver = $sd_ver"
    #log "DEBUG: sd_ver_short = $sd_ver_short"
    #log "DEBUG: sd_run = $sd_run"
    #log "DEBUG: sd_file = $sd_file"

    # Create status data file
    rm -f "$sd_file"
    insights-perf/status_data.py --status-data-file $sd_file --set \
        "name=$sd_section/$sd_name" \
        "parameters.cli=$( echo "$sd_cli" | sed 's/=/__/g' )" \
        "parameters.version=$sd_ver" \
        "parameters.run=$sd_run" \
        "results.log=$sd_log" \
        "results.rc=$sd_rc" \
        "results.duration=$sd_duration" \
        "started=$sd_start" \
        "ended=$sd_end"

    # Add monitoring data to the status data file
    log "DEBUG: PARAM_cluster_read_config = $PARAM_cluster_read_config"
    log "DEBUG: PARAM_grafana_host = $PARAM_grafana_host"
    if [ -n "$PARAM_cluster_read_config" -a -n "$PARAM_grafana_host" ]; then
        insights-perf/status_data.py --status-data-file $sd_file --debug \
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
        insights-perf/data_investigator.py --data-from-es \
            --data-from-es-matcher "results.rc=0" "parameters.cli=$sd_cli" \
            --data-from-es-wildcard "parameters.version=*$sd_ver_short*" \
            --es-host $PARAM_elasticsearch_host \
            --es-port $PARAM_elasticsearch_port --es-index satellite_perf_index --es-type cpt \
            --test-from-status "$sd_file" &>$sd_result_log \
            && rc=$? || rc=$?
        if [ "$rc" -eq 0 ]; then
            sd_result='PASS'
        else
            sd_result='FAIL'
        fi
    else
        sd_result='ERROR'
    fi
    #log "DEBUG: sd_result = $sd_result"

    # Add result to the status data so it is complete
    insights-perf/status_data.py --status-data-file $sd_file --set "result=$sd_result"

    # Upload status data to ElasticSearch
    curl --silent -H "Content-Type: application/json" -X POST \
        "http://$PARAM_elasticsearch_host:$PARAM_elasticsearch_port/satellite_perf_index/cpt/" \
        --data "@$sd_file" \
            | python -c "import sys, json; obj, pos = json.JSONDecoder().raw_decode(sys.stdin.read()); assert obj['_shards']['successful'] == 1 and obj['_shards']['failed'] == 0, 'Failed to upload status data'"
    ###insights-perf/status_data.py --status-data-file $sd_file --info

    # Enhance log file
    tmp=$( mktemp )
    echo "command: $sd_cli" >>$tmp
    echo "version: $sd_ver" >>$tmp
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
}

function junit_upload() {
    # Upload junit.xml into ReportPortal for test result investigation

    [ -z "$PARAM_reportportal_host" ] && return 0

    zip_name="SatPerf-ContPerf-$( echo "$satellite_version" | sed 's/^satellite-//' | sed 's/^\([0-9]\+\.[0-9]\+\).*/\1/' ).zip"
    rm -f $zip_name
    zip --quiet "$zip_name" "$logs/junit.xml"
    curl --silent --insecure -X POST --header 'Accept: application/json' \
        --header "Authorization: bearer $PARAM_reportportal_token" \
        --form "file=@$zip_name" \
        "https://$PARAM_reportportal_host/api/v1/$PARAM_reportportal_project/launch/import" \
            | grep --quiet 'Launch with id = [0-9a-f]\+ is successfully imported' \
                || echo "Failed to upload junit" >&2
    rm -f "$zip_name"
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
        rc=0
    else
        eval "$@" &>$out && rc=$? || rc=$?
    fi
    local end=$( date --utc +%s )
    log "Finish after $( expr $end - $start ) seconds with log in $out and exit code $rc"
    measurement_add "$@" "$out" "$rc" "$start" "$end" "$satellite_version" "$marker"
    return $rc
}

function a() {
    local out=$logs/$1; shift
    mkdir -p $( dirname $out )
    local start=$( date --utc +%s )
    log "Start 'ansible $opts_adhoc $*' with log in $out"
    if $run_lib_dryrun; then
        log "FAKE ansible RUN"
        rc=0
    else
        ansible $opts_adhoc "$@" &>$out && rc=$? || rc=$?
    fi
    rc=$?
    local end=$( date --utc +%s )
    log "Finish after $( expr $end - $start ) seconds with log in $out and exit code $rc"
    measurement_add "ansible $opts_adhoc $( _format_opts "$@" )" "$out" "$rc" "$start" "$end" "$satellite_version" "$marker"
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
        rc=0
    else
        ansible-playbook $opts "$@" &>$out && rc=$? || rc=$?
    fi
    rc=$?
    local end=$( date --utc +%s )
    log "Finish after $( expr $end - $start ) seconds with log in $out and exit code $rc"
    measurement_add "ansible-playbook $opts $( _format_opts "$@" )" "$out" "$rc" "$start" "$end" "$satellite_version" "$marker"
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
            local out=$( ./reg-average.sh "$grepper" "$log" 2>/dev/null | grep "^$grepper in " | tail -n 1 )
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
