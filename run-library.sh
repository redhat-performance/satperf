#!/bin/bash

set -o pipefail
###set -x
set -e


opts=${opts:-"--forks 100 -i conf/20170625-gprfc019.ini"}
opts_adhoc=${opts_adhoc:-"$opts --user root"}
logs=${logs:-"logs-$( date --iso-8601=seconds )"}
run_lib_dryrun=false
hammer_opts="-u admin -p changeme"

# We need to add an ID to run-bench runs to be able to filter out results from multiple runs. This ID will be appended as
# the last field of lines in measurements.log file.
# The ID should be passed as a argument to the run-bench.sh. If there is no argument passed, default ID will be
# generated based on the current date and time.
bench_run_id=${1:-$(date --iso-8601=seconds)}

# Requirements check
if ! type bc >/dev/null; then
    echo "ERROR: bc not installed" >&2
    exit 1
fi
if ! type ansible >/dev/null; then
    echo "ERROR: ansible not installed" >&2
    exit 1
fi


function log() {
    echo "[$( date --iso-8601=seconds )] $*"
}

function a() {
    local out=$logs/$1; shift
    mkdir -p $( dirname $out )
    local start=$( date +%s )
    log "Start 'ansible $opts_adhoc $*' with log in $out"
    if $run_lib_dryrun; then
        log "FAKE ansible RUN"
    else
        ansible $opts_adhoc "$@" &>$out
    fi
    rc=$?
    local end=$( date +%s )
    log "Finish after $( expr $end - $start ) seconds with log in $out and exit code $rc"
    echo "$( echo "ansible $opts_adhoc $@" | sed 's/,/_/g' ),$out,$rc,$start,$end,${bench_run_id}" >>$logs/measurement.log
    return $rc
}

function a_out() {
    if $run_lib_dryrun; then
        echo "FAKE ansible RUN"
    else
        ansible $opts_adhoc "$@"
    fi
}

function ap() {
    local out=$logs/$1; shift
    mkdir -p $( dirname $out )
    local start=$( date +%s )
    log "Start 'ansible-playbook $opts $*' with log in $out"
    if $run_lib_dryrun; then
        log "FAKE ansible-playbook RUN"
    else
        ansible-playbook $opts "$@" &>$out
    fi
    rc=$?
    local end=$( date +%s )
    log "Finish after $( expr $end - $start ) seconds with log in $out and exit code $rc"
    echo "$( echo "ansible-playbook $opts_adhoc $@" | sed 's/,/_/g' ),$out,$rc,$start,$end,${bench_run_id}" >>$logs/measurement.log
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
        local rc="$( echo "$row" | cut -d ',' -f 3 )"
        if [ "$rc" -ne 0 ]; then
            echo "ERROR: Row '$row' have non-zero return code. Not considering it when counting duration :-(" >&2
            continue
        fi
        if [ -n "$grepper" ]; then
            local log="$( echo "$row" | cut -d ',' -f 2 )"
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
            local start="$( echo "$row" | cut -d ',' -f 4 )"
            local end="$( echo "$row" | cut -d ',' -f 5 )"
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
mkdir "$logs/"
log "Logging into '$logs/' directory"
