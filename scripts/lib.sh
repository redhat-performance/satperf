#!/bin/sh

# This expects you have lots of containers available and their IPs in file
# container-ips which have format:
#
#   # head -n 3 container-ips
#   a6ccc312d286771261cb337504fd214f0cafe74dad39fa0339874a6fcf6d9360 192.168.122.100
#   3cacfc995a6c962a1ac0943983abdb321608219cfb82e35df8ba7de43d5dfc39 192.168.122.101
#   467187bc9bd0014b40ad6f30b00d2e2a39480ff24cf96069c1fe6e9062fcb75f 192.168.122.102
#
# In setup we have used we had 5 VMs running with networking set and this
# was used to create all the containers:
#
#   Check seup of the VMs (docker hosts)
#   # for h in docker1 docker2 docker3 docker4 docker5; do
#       echo "=== $h ==="
#       ssh root@$h 'hostname'
#       ssh root@$h 'grep -- "--fixed-cidr" /etc/sysconfig/docker'
#       ssh root@$h 'grep ^IPADDR /etc/sysconfig/network-scripts/ifcfg-docker0'
#       ssh root@$h 'docker ps -q | wc -l'
#   done
#
#   Start all the containers
#   # for h in docker1 docker2 docker3 docker4 docker5; do
#       # Wondering why the "-v /tmp/yum-cache-$i/:/var/cache/yum/" there?
#       # See https://github.com/optimizationBenchmarking/environments-linux-evaluator-runtime/commit/d00176e9cad3f54bf0b9f789e8e64e544290a281
#       ssh root@$h 'for i in `seq 250`; do [ -d /tmp/yum-cache-$i/ ] || mkdir /tmp/yum-cache-$i/; docker run -d -v /tmp/yum-cache-$i/:/var/cache/yum/ r7perfsat; done' &
#   done
#
#   Get IPs of all the contaiers
#   # for h in docker1 docker2 docker3 docker4 docker5; do
#       ssh root@$h 'for c in $(docker ps -q); do docker inspect $c | python -c "import json,sys;obj=json.load(sys.stdin);print obj[0][\"Id\"], obj[0][\"NetworkSettings\"][\"IPAddress\"]"; done'
#   done >container-ips


function log() {
    echo "[$( date )]: $*"
}


function warn() {
    log "WARN: $*" >&2
}


function die() {
    log "ERROR: $*" >&2
    exit 1
}


function get_list() {
    local list=$1
    local queue=$2
    local batch=$3
    local offset=$4
    if [ ! -w "$list" -o -z "$queue" -o -z "$batch" -o -z "$offset" -o $# -ne 4 ]; then
        die "Function get_list called with incorrect params $*"
    fi
    case $queue in
        random)
            cut -d ' ' -f 2 /root/container-ips \
                | sort --random-sort \
                | head -n $batch > $list
            log "RUNNING BATCH OF $batch REGISTRATIONS ($queue)"
        ;;
        sequence)
            # We need to choose from randomly sorted list not to overload one
            # docker host, but that randomly sorted list have to be same each
            # time so with different $offset we get different IPs
            if [ ! -f /root/container-ips.shuffled ] ||
               ! cmp <( sort /root/container-ips ) <( sort /root/container-ips.shuffled ); then
                warn "Shufeling /root/container-ips to /root/container-ips.shuffled"
                sort --random-sort /root/container-ips > /root/container-ips.shuffled
            fi
            head -n $( expr $batch \* $offset + $batch ) /root/container-ips.shuffled \
                | tail -n $batch \
                | cut -d ' ' -f 2 > $list
            log "RUNNING BATCH OF $batch REGISTRATIONS ($queue from line $( expr $batch \* $offset ) to $( expr $batch \* $offset + $batch ))"
        ;;
        *)
            die "Unknown queue type '$queue'"
        ;;
    esac
    [[ $( wc -l $list | cut -d ' ' -f 1 ) -ne $batch ]] \
        && die "Was not able to determine IPs to use (see '$list')"
}


function ansible_playbook() {
    local playbook=$1
    local forks=${2:-50}
    local log=$( mktemp )
    ansible-playbook -i $list --forks $forks $playbook &>$log \
        && log "$playbook passed (full log in '$log')" \
        || die "$playbook failed (full log in '$log')"
}


function ansible_errors_histogram() {
    local log=$1
    local ansible_failed_re="^[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+ | FAILED"   # Ansible 2.0 and 1.9 differs here
    local uuid_re="[a-f0-9]\{8\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{12\}"
    local time_re="[0-9]\{1,2\}:[0-9]\{2\}:[0-9]\{2\}\.[0-9]\+"
    local date_re="[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}"
    if [ ! -r $log ]; then
        die "Function ansible_errors_histogram is unable to read file '$1'"
    fi
    if [[ $( grep "$ansible_failed_re" $log | wc -l | cut -d ' ' -f 1 ) -eq 0 ]]; then
        log "No errors encountered here (full log in '$log')"
        grep "FAILED" $log || true   # just to be sure there were really no failures
    else
        log "Errors encountered were (full log in '$log'):"
        grep "$ansible_failed_re" $log \
            | sed -e "s/$ansible_failed_re//" \
                  -e "s/$uuid_re/<uuid>/" \
                  -e "s/$date_re/<date>/g" \
                  -e "s/$time_re/<time>/g" \
                | sort | uniq -c
    fi
}
