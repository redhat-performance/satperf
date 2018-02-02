#!/bin/bash

###set -x
set -e


opts=${opts:-"--forks 100 -i conf/20170625-gprfc019.ini"}
opts_adhoc=${opts_adhoc:-"$opts --user root"}
logs=${logs:-"logs-$( date --iso-8601=seconds )"}

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
    ansible $opts_adhoc "$@" &>$out
    rc=$?
    local end=$( date +%s )
    log "Finish after $( expr $end - $start ) seconds with exit code $rc"
    echo "$( echo "ansible $opts_adhoc $@" | sed 's/,/_/g' ),$out,$rc,$start,$end" >>$logs/measurement.log
    return $rc
}

function ap() {
    local out=$logs/$1; shift
    mkdir -p $( dirname $out )
    local start=$( date +%s )
    log "Start 'ansible-playbook $opts $*' with log in $out"
    ansible-playbook $opts "$@" &>$out
    rc=$?
    local end=$( date +%s )
    log "Finish after $( expr $end - $start ) seconds with exit code $rc"
    echo "$( echo "ansible-playbook $opts_adhoc $@" | sed 's/,/_/g' ),$out,$rc,$start,$end" >>$logs/measurement.log
    return $rc
}

function s() {
    log "Sleep for $1 seconds"
    sleep $1
}


# Create dir for logs
mkdir "$logs/"
log "Logging into '$logs/' directory"
