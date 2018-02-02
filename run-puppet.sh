#!/bin/bash

source run-library.sh

opts="--forks 100 -i conf/20170625-gprfc019.ini"
opts_adhoc="$opts --user root --timeout 180"

function measure_pmps() {
    # $1 ... base scenario name
    # $2 ... PassengerMaxPoolSize
    log "Start case $1 with $2 setting for PassengerMaxPoolSize"
    d=$1/$2

    case $2 in
        3)
            a $d/set.log -m "lineinfile" -a "path=/etc/httpd/conf.d/passenger.conf regexp=\"^\s*PassengerMaxPoolSize\" line=\"   PassengerMaxPoolSize 3\" insertbefore=\"^</IfModule>\"" satellite6
            ;;
        default)
            a $d/set.log -m "lineinfile" -a "path=/etc/httpd/conf.d/passenger.conf regexp=\"PassengerMaxPoolSize\" line=\"   ###PassengerMaxPoolSize\" insertbefore=\"^</IfModule>\"" satellite6
            ;;
        9)
            a $d/set.log -m "lineinfile" -a "path=/etc/httpd/conf.d/passenger.conf regexp=\"^\s*PassengerMaxPoolSize\" line=\"   PassengerMaxPoolSize 9\" insertbefore=\"^</IfModule>\"" satellite6
            ;;
        12)
            a $d/set.log -m "lineinfile" -a "path=/etc/httpd/conf.d/passenger.conf regexp=\"^\s*PassengerMaxPoolSize\" line=\"   PassengerMaxPoolSize 12\" insertbefore=\"^</IfModule>\"" satellite6
            ;;
        *)
            echo "ERROR, unknown PassengerMaxPoolSize setting $2" >&2
            exit 1
            ;;
    esac
    a $d/restart.log -m "shell" -a "katello-service stop; swapoff -a; echo 3 > /proc/sys/vm/drop_caches; swapon -a; katello-service start" satellite6

    ap $d/puppet.log playbooks/tests/puppet.yaml

    log "Finish case $1 with $2"
}

function measure() {
    # $1 ... scenario name
    # $2 ... VM name
    log "Start scenario $1 on $2"
    d="$1/$2"

    a $d/boot.log -m "shell" -a "for vm in \$( virsh list --name ); do virsh shutdown \"\$vm\"; done; while [ \$( virsh list --name | grep -v '^\s*$' | wc -l | cut -d ' ' -f 1 ) -gt 0 ]; do sleep 1; done; virsh start '$2'" gprfc019.sbu.lab.eng.bos.redhat.com
    a $d/set-cleanup.log -m "lineinfile" -a "path=/etc/httpd/conf.d/passenger.conf regexp=\"PassengerMaxPoolSize\" state=\"absent\"" satellite6

    # Measure for different PassengerMaxPoolSize settings
    measure_pmps $d 3
    ###measure_pmps $d default
    ###measure_pmps $d 9
    ###measure_pmps $d 12

    log "Showing average duration of 10 'puppet agent --test' runs"
    ./reg-average.sh 'Puppet agent run' $d/*/puppet.log

    log "Finish scenario $1 on $2"
}

function doit() {
    log "START RUN"

    ap $1/reg-1st-40.log playbooks/tests/registrations.yaml -e "size=5 resting=30 tags='untagged,REGTIMEOUTTWEAK,REG,PUP' save_graphs=false"
    ap $1/reg-2nd-40.log playbooks/tests/registrations.yaml -e "size=5 resting=30 tags='untagged,REGTIMEOUTTWEAK,REG,PUP' save_graphs=false"
    ap $1/puppet-setup.log playbooks/tests/puppet-setup.yaml
    s 100

    # Measure on VM with different RAM setting
    measure $1 "gprfc019-vm1-12GB"
    ###measure $1 "gprfc019-vm1-16GB"
    ###measure $1 "gprfc019-vm1-20GB"

    log "FINISH RUN"
}

function setup() {
    ap $1-remove-hosts-pre.log playbooks/satellite/satellite-remove-hosts.yaml &
    ap $1-docker-tierdown.log  playbooks/satellite/docker-tierdown.yaml
    ap $1-docker-tierup.log    playbooks/satellite/docker-tierup.yaml
    wait
}



world="results-puppet-$( date +%Y%m%d )-gprfc019"

# Recreate clients, remove them from Satellite
setup "$world"

# Each time 'doit' is started, 80 more clients is created
doit "$world-80clients" 2>&1 | tee $scenario.log
doit "$world-160clients" 2>&1 tee $scenario.log
doit "$world-240clients" 2>&1 | tee $scenario.log
