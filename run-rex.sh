#!/bin/bash

###set -x
set -e

opts="--forks 100 -i conf/20170625-gprfc019.ini"
opts_adhoc="$opts --user root"

function log() {
    echo "[$( date --iso-8601=seconds )] $*"
}

function a() {
    local out=$1; shift
    local start=$( date +%s )
    log "Start 'ansible $opts_adhoc $*'"
    ansible $opts_adhoc "$@" &>$out
    rc=$?
    local end=$( date +%s )
    log "Finish after $( expr $end - $start ) seconds with exit code $rc"
    return $rc
}
function ap() {
    local out=$1; shift
    local start=$( date +%s )
    log "Start 'ansible-playbook $opts $*'"
    ansible-playbook $opts "$@" &>$out
    rc=$?
    local end=$( date +%s )
    log "Finish after $( expr $end - $start ) seconds with exit code $rc"
    return $rc
}
function s() {
    log "Sleep for $1 seconds"
    sleep $1
}

function measure() {
    log "Start scenario $1"
    mkdir $1

    ap $1-remove-hosts-pre.log playbooks/satellite/satellite-remove-hosts.yaml

    a $1/restart.log -m "shell" -a "katello-service stop; swapoff -a; echo 3 > /proc/sys/vm/drop_caches; swapon -a; katello-service start" satellite6
    s 120

    ap $1/reg-1st-40.log playbooks/tests/registrations.yaml -e "size=5 resting=30 tags='untagged,REGTIMEOUTTWEAK,REG,DOWNGRADE,REM,INSTKAT' save_graphs=false"
    ap $1/reg-2nd-40.log playbooks/tests/registrations.yaml -e "size=5 resting=30 tags='untagged,REGTIMEOUTTWEAK,REG,DOWNGRADE,REM,INSTKAT' save_graphs=false"
    ap $1/reg-3rd-40.log playbooks/tests/registrations.yaml -e "size=5 resting=30 tags='untagged,REGTIMEOUTTWEAK,REG,DOWNGRADE,REM,INSTKAT' save_graphs=false"
    s 100
    ap $1/rex-120.log playbooks/tests/rex.yaml
    s 100
    ap $1/reg-4th-40.log playbooks/tests/registrations.yaml -e "size=5 resting=30 tags='untagged,REGTIMEOUTTWEAK,REG,DOWNGRADE,REM,INSTKAT' save_graphs=false"
    ap $1/reg-5th-40.log playbooks/tests/registrations.yaml -e "size=5 resting=30 tags='untagged,REGTIMEOUTTWEAK,REG,DOWNGRADE,REM,INSTKAT' save_graphs=false"
    ap $1/reg-6th-40.log playbooks/tests/registrations.yaml -e "size=5 resting=30 tags='untagged,REGTIMEOUTTWEAK,REG,DOWNGRADE,REM,INSTKAT' save_graphs=false"
    s 100
    ap $1/rex-240.log playbooks/tests/rex.yaml
    s 100
    ap $1/reg-7th-40.log playbooks/tests/registrations.yaml -e "size=5 resting=30 tags='untagged,REGTIMEOUTTWEAK,REG,DOWNGRADE,REM,INSTKAT' save_graphs=false"
    ap $1/reg-8th-40.log playbooks/tests/registrations.yaml -e "size=5 resting=30 tags='untagged,REGTIMEOUTTWEAK,REG,DOWNGRADE,REM,INSTKAT' save_graphs=false"
    ap $1/reg-9th-40.log playbooks/tests/registrations.yaml -e "size=5 resting=30 tags='untagged,REGTIMEOUTTWEAK,REG,DOWNGRADE,REM,INSTKAT' save_graphs=false"
    s 100
    ap $1/rex-360.log playbooks/tests/rex.yaml
    s 100
    ap $1/reg-10th-40.log playbooks/tests/registrations.yaml -e "size=5 resting=30 tags='untagged,REGTIMEOUTTWEAK,REG,DOWNGRADE,REM,INSTKAT' save_graphs=false"
    ap $1/reg-11th-40.log playbooks/tests/registrations.yaml -e "size=5 resting=30 tags='untagged,REGTIMEOUTTWEAK,REG,DOWNGRADE,REM,INSTKAT' save_graphs=false"
    ap $1/reg-12th-40.log playbooks/tests/registrations.yaml -e "size=5 resting=30 tags='untagged,REGTIMEOUTTWEAK,REG,DOWNGRADE,REM,INSTKAT' save_graphs=false"
    s 100
    ap $1/rex-480.log playbooks/tests/rex.yaml

    ap $1-remove-hosts-post.log playbooks/satellite/satellite-remove-hosts.yaml

    log "Showing average registration time"
    grep 'RESULT' $1/rex-*.log || true

    log "Finish scenario $1"
}

function doit() {
    # $1 ... scenario name
    # $2 ... VM name
    log "START RUN"

    a $1-boot.log               -m "shell" -a "for d in \$( virsh list --name ); do virsh shutdown \"\$d\"; done; while [ \$( virsh list --name | grep -v '^\s*$' | wc -l | cut -d ' ' -f 1 ) -gt 0 ]; do sleep 1; done; virsh start '$2'" gprfc019.sbu.lab.eng.bos.redhat.com
    ap $1-docker-tierdown.log   playbooks/satellite/docker-tierdown.yaml
    ap $1-docker-tierup.log     playbooks/satellite/docker-tierup.yaml
    a $1-set-cleanup.log        -m "lineinfile" -a "path=/etc/httpd/conf.d/passenger.conf regexp=\"PassengerMaxPoolSize\" state=\"absent\"" satellite6

    a $1-set-3.log              -m "lineinfile" -a "path=/etc/httpd/conf.d/passenger.conf regexp=\"^\s*PassengerMaxPoolSize\" line=\"   PassengerMaxPoolSize 3\" insertbefore=\"^</IfModule>\"" satellite6
    measure $1-3

    a $1-set-default.log        -m "lineinfile" -a "path=/etc/httpd/conf.d/passenger.conf regexp=\"PassengerMaxPoolSize\" line=\"   ###PassengerMaxPoolSize\" insertbefore=\"^</IfModule>\"" satellite6
    measure $1-default

    a $1-set-9.log              -m "lineinfile" -a "path=/etc/httpd/conf.d/passenger.conf regexp=\"^\s*PassengerMaxPoolSize\" line=\"   PassengerMaxPoolSize 9\" insertbefore=\"^</IfModule>\"" satellite6
    measure $1-9

    a $1-set-12.log             -m "lineinfile" -a "path=/etc/httpd/conf.d/passenger.conf regexp=\"^\s*PassengerMaxPoolSize\" line=\"   PassengerMaxPoolSize 12\" insertbefore=\"^</IfModule>\"" satellite6
    measure $1-12

    log "FINISH RUN"
}



scenario="results-rex-$( date +%Y%m%d )-gprfc019-12GB"
doit "$scenario" "gprfc019-vm1-12GB" 2>&1 | tee $scenario.log
scenario="results-rex-$( date +%Y%m%d )-gprfc019-16GB"
doit "$scenario" "gprfc019-vm1-16GB" 2>&1 | tee $scenario.log
scenario="results-rex-$( date +%Y%m%d )-gprfc019-20GB"
doit "$scenario" "gprfc019-vm1-20GB" 2>&1 | tee $scenario.log

###X=delme
###mkdir $X
###ap $X-remove-hosts-pre.log  playbooks/satellite/satellite-remove-hosts.yaml
###ap $X/reg-1st-40.log playbooks/tests/registrations.yaml -e "size=5 resting=0 tags='untagged,REGTIMEOUTTWEAK,REG,DOWNGRADE,REM,INSTKAT'"   # register, downgrade, install katello-agent (for katello-package-upload)
###d=$( date --iso-8601=seconds )
###a $X/rex-date-40.log -m "shell" -a "hammer -u admin -p changeme job-invocation create --description-format 'Date with 40 ($d)' --dynamic --search-query 'container' --job-template 'Run Command - SSH Default' --inputs \"command='date'\" --async" satellite6 &
###s 30
###kill $!   # looks like it keeps waiting even with "--async"
###./wait-for-job.py admin changeme https://gprfc019-vm1.sbu.lab.eng.bos.redhat.com/ 28
