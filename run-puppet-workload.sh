#!/bin/bash

source run-library.sh

sleep_time=60
opts="--forks 100 -i conf/miniperf/inventory.ini"
opts_adhoc="$opts --user root"

# Checked that all works and then remove "-e" flag so every error do not terminate whole run
a check-ping-docker.log satellite6 -m "shell" -a "ping -c 3 {{ groups['docker-hosts']|first }}"
a check-ping-sat.log docker-hosts -m "shell" -a "ping -c 3 {{ groups['satellite6']|first }}"
a check-hammer-ping.log satellite6 -m "shell" -a "! ( hammer -u admin -p changeme ping | grep 'Status:' | grep -v 'ok$' )"
a check-sat-content.log satellite6 -m "shell" -a "hammer -u admin -p changeme os info --id 1 | grep 'Family:\s\+Redhat'"
set +e

# Prepare environment
ap satellite-puppet-big-cv.log playbooks/tests/puppet-big-setup.yaml &
ap satellite-remove-hosts.log playbooks/satellite/satellite-remove-hosts.yaml &
ap docker-tierdown-tierup.log playbooks/docker/docker-tierdown.yaml playbooks/docker/docker-tierup.yaml &
ap docker-client-scripts.log playbooks/satellite/client-scripts.yaml &
a rex-cleanup-know_hosts.log satellite6 -m "shell" -a "rm -rf /usr/share/foreman-proxy/.ssh/known_hosts*" &
wait
a satellite-drop-caches.log -m shell -a "katello-service stop; sync; echo 3 > /proc/sys/vm/drop_caches; katello-service start" satellite6
s $sleep_time

function reg_five() {
    # Register "$1 * 5 * number_of_docker_hosts" containers, do not change /root/container-used-count on docker hosts
    d=$( date --utc --iso-8601=seconds )
    a $d-backup-used-containers-count.log -m shell -a "touch /root/container-used-count; cp /root/container-used-count{,.foobarbaz}" docker-hosts
    for i in $( seq $1 ); do
        ap reg-$d-$i.log playbooks/tests/registrations.yaml -e "size=5 tags=untagged,REG,REM bootstrap_retries=3 grepper='Register'"
        log "$( ./reg-average.sh Register $logs/reg-$d-$i.log | tail -n 1 )"
        s $sleep_time
    done
    a $d-restore-used-containers-count.log -m shell -a "cp /root/container-used-count{.foobarbaz,}" docker-hosts
}

function measure() {
    local concurency=$1
    local host_fives=$(( $concurency / 5 ))
    log "===== Register and apply one with concurency $concurency: $( date --utc ) ====="

    reg_five $host_fives
    ap $concurency-PuppetOne.log playbooks/tests/puppet-big-test.yaml --tags REGISTER,DEPLOY_SINGLE -e "size=$concurency"
    log "$( ./reg-average.sh RegisterPuppet $logs/$concurency-PuppetOne.log | tail -n 1 )"
    log "$( ./reg-average.sh PickupPuppet $logs/$concurency-PuppetOne.log | tail -n 1 )"
    s $sleep_time
}

measure 5
measure 10
measure 20
measure 30
measure 40
measure 50
measure 60

ap satellite-remove-hosts.log playbooks/satellite/satellite-remove-hosts.yaml &
ap docker-tierdown-tierup.log playbooks/docker/docker-tierdown.yaml playbooks/docker/docker-tierup.yaml playbooks/satellite/client-scripts.yaml &
a rex-cleanup-know_hosts.log satellite6 -m "shell" -a "rm -rf /usr/share/foreman-proxy/.ssh/known_hosts*" &
wait
s $sleep_time

function measure_lots() {
    local concurency=$1
    log "===== Apply bunch with concurency $concurency: $( date --utc ) ====="

    ap $concurency-PuppetBunch.log playbooks/tests/puppet-big-test.yaml --tags REGISTER,DEPLOY_BUNCH -e "size=$concurency"
    log "$( ./reg-average.sh SetupPuppet $logs/$concurency-PuppetBunch.log | tail -n 1 )"
    log "$( ./reg-average.sh PickupPuppet $logs/$concurency-PuppetBunch.log | tail -n 1 )"
    s $sleep_time
}

log "===== Registering hosts for experiment with lots of modules: $( date --utc ) ====="
reg_five 15   # so we have 15 * 5 = 75 registered containers on each docker host

measure_lots 2
measure_lots 6
measure_lots 10
measure_lots 14
measure_lots 18
measure_lots 22
measure_lots 26
measure_lots 30
measure_lots 34
measure_lots 38
