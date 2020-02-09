#!/bin/bash

source experiment/run-library.sh

opts="--forks 100 -i conf/20170625-gprfc019.ini"
opts_adhoc="$opts --user root"

function measure() {
    log "Start scenario $1"

    a $1/restart.log -m "shell" -a "katello-service stop; swapoff -a; echo 3 > /proc/sys/vm/drop_caches; swapon -a; katello-service start" satellite6
    s 120

    ap $1/reg-05.log playbooks/tests/registrations.yaml -e "size=5 resting=0"
    s 100
    ap $1/reg-10.log playbooks/tests/registrations.yaml -e "size=10 resting=0"
    s 100
    ap $1/reg-15.log playbooks/tests/registrations.yaml -e "size=15 resting=0"
    s 100
    ap $1/reg-20.log playbooks/tests/registrations.yaml -e "size=20 resting=0"

    log "Showing average registration time"
    ./reg-average.sh 'Register' $1/reg-*.log

    log "Finish scenario $1"
}

function doit() {
    # $1 ... scenario name
    # $2 ... VM name
    log "START RUN"

    a $1-boot.log               -m "shell" -a "for vm in \$( virsh list --name ); do virsh shutdown \"\$vm\"; done; while [ \$( virsh list --name | grep -v '^\s*$' | wc -l | cut -d ' ' -f 1 ) -gt 0 ]; do sleep 1; done; virsh start '$2'" gprfc019.sbu.lab.eng.bos.redhat.com
    ap $1-docker-tierdown.log   playbooks/satellite/docker-tierdown.yaml
    ap $1-docker-tierup.log     playbooks/satellite/docker-tierup.yaml
    ap $1-remove-hosts-pre.log  playbooks/satellite/satellite-remove-hosts.yaml
    a $1-set-cleanup.log        -m "lineinfile" -a "path=/etc/httpd/conf.d/passenger.conf regexp=\"PassengerMaxPoolSize\" state=\"absent\"" satellite6

    a $1-set-3.log              -m "lineinfile" -a "path=/etc/httpd/conf.d/passenger.conf regexp=\"^\s*PassengerMaxPoolSize\" line=\"   PassengerMaxPoolSize 3\" insertbefore=\"^</IfModule>\"" satellite6
    measure $1-3

    a $1-set-default.log        -m "lineinfile" -a "path=/etc/httpd/conf.d/passenger.conf regexp=\"PassengerMaxPoolSize\" line=\"   ###PassengerMaxPoolSize\" insertbefore=\"^</IfModule>\"" satellite6
    measure $1-default

    a $1-set-9.log              -m "lineinfile" -a "path=/etc/httpd/conf.d/passenger.conf regexp=\"^\s*PassengerMaxPoolSize\" line=\"   PassengerMaxPoolSize 9\" insertbefore=\"^</IfModule>\"" satellite6
    measure $1-9

    a $1-set-12.log             -m "lineinfile" -a "path=/etc/httpd/conf.d/passenger.conf regexp=\"^\s*PassengerMaxPoolSize\" line=\"   PassengerMaxPoolSize 12\" insertbefore=\"^</IfModule>\"" satellite6
    measure $1-12

    ap $1-remove-hosts-post.log playbooks/satellite/satellite-remove-hosts.yaml

    log "FINISH RUN"
}



scenario="results-reg-$( date +%Y%m%d )-gprfc019-12GB"
doit "$scenario" "gprfc019-vm1-12GB" 2>&1 | tee $scenario.log
scenario="results-reg-$( date +%Y%m%d )-gprfc019-16GB"
doit "$scenario" "gprfc019-vm1-16GB" 2>&1 | tee $scenario.log
scenario="results-reg-$( date +%Y%m%d )-gprfc019-20GB"
doit "$scenario" "gprfc019-vm1-20GB" 2>&1 | tee $scenario.log
