#!/bin/bash

source run-library.sh

opts="--forks 100 -i conf/20171214-bagl-puppet4.ini"
opts_adhoc="$opts --user root"

###ap satellite-remove-hosts.log playbooks/satellite/satellite-remove-hosts.yaml &
###ap docker-tierdown-tierup.log playbooks/docker/docker-tierdown.yaml playbooks/docker/docker-tierup.yaml &
###wait

function reg_five() {
    # Register "$1 * 5 * number_of_docker_hosts" containers
    d=$( date --iso-8601=seconds )
    for i in $( seq $1 ); do
        ap reg-$d-$i.log playbooks/tests/registrations.yaml -e "size=5 tags=untagged,REG,REM,PUP,PUP_STOP bootstrap_retries=3"
        s 300
    done
}

function measure() {
    local concurency=$1
    local host_fives=$(( $concurency / 5 ))
    log "===== Concurency $concurency: $( date ) ====="
    a $concurency-backup-used-containers-count.log -m shell -a "cp /root/container-used-count{,.foobarbaz}" docker-hosts
    reg_five $host_fives
    a $concurency-restore-used-containers-count.log -m shell -a "cp /root/container-used-count{.foobarbaz,}" docker-hosts
    ap $concurency-PUPDEPLOYSETUP.log playbooks/tests/registrations.yaml -e "size=$concurency tags=PUPDEPLOYSETUP update_used=false"
    s 100
    ap $concurency-PUPDEPLOY.log playbooks/tests/registrations.yaml -e "size=$concurency tags=PUPDEPLOY grepper='PickupPuppet'"
    ./reg-average.sh PickupPuppet $logs/$concurency-PUPDEPLOY.log
    log "Failed waits for a deployed file: $( a_out -m shell -a 'grep "^fatal" "$( ls /root/out-*.log | sort | tail -n 1 )"' docker-hosts | grep ^fatal | wc -l )"
    s 300
}

measure 10
measure 20
measure 30
