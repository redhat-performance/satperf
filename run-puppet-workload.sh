#!/bin/bash

source run-library.sh

opts="--forks 100 -i conf/20171214-bagl-puppet4.ini"
opts_adhoc="$opts --user root"

### FIXME
run_lib_dryrun=true

ap satellite-remove-hosts.log playbooks/satellite/satellite-remove-hosts.yaml &
ap docker-tierdown-tierup.log playbooks/docker/docker-tierdown.yaml playbooks/docker/docker-tierup.yaml &
wait

exit 0

function reg() {
    for i in $( seq $1 ); do
        ansible-playbook --forks 100 -i conf/20171214-bagl-puppet4.ini playbooks/tests/registrations.yaml -e "size=5 tags=untagged,REG,REM,PUP bootstrap_retries=3" >/tmp/reg-$i.log;
        echo "Registering 5 * 10 systems: $?"
        sleep 300
    done
}

log "===== 10: $( date ) ====="
reg 2
sleep 100
ansible --forks 100 -i conf/20171214-bagl-puppet4.ini --user root -m shell -a "echo 0 >/root/container-used-count" docker-hosts >/dev/null
echo "Reset used containers counter: $?"
ansible-playbook --forks 100 -i conf/20171214-bagl-puppet4.ini playbooks/tests/registrations.yaml -e "size=10 tags=PUPDEPLOYSETUP update_used=false" >/tmp/PUPDEPLOYSETUP-10.log
echo "PUPDEPLOYSETUP: $?"
sleep 100
ansible-playbook --forks 100 -i conf/20171214-bagl-puppet4.ini playbooks/tests/registrations.yaml -e "size=10 tags=PUPDEPLOY grepper='PickupPuppet'" >/tmp/PUPDEPLOY-10.log
echo "PUPDEPLOY: $?"
./reg-average.sh PickupPuppet /tmp/PUPDEPLOY-10.log
echo -n "Failed waits for a deployed file:"
ansible --forks 100 -i conf/20171214-bagl-puppet4.ini --user root -m shell -a 'grep "^fatal" "$( ls /root/out-*.log | sort | tail -n 1 )"' docker-hosts | grep ^fatal | wc -l
sleep 300

log "===== 20: $( date ) ====="
reg 4
sleep 100
ansible --forks 100 -i conf/20171214-bagl-puppet4.ini --user root -m shell -a "echo 10 >/root/container-used-count" docker-hosts >/dev/null
ansible-playbook --forks 100 -i conf/20171214-bagl-puppet4.ini playbooks/tests/registrations.yaml -e "size=20 tags=PUPDEPLOYSETUP update_used=false" >/tmp/PUPDEPLOYSETUP-20.log
echo "PUPDEPLOYSETUP: $?"
sleep 100
ansible-playbook --forks 100 -i conf/20171214-bagl-puppet4.ini playbooks/tests/registrations.yaml -e "size=20 tags=PUPDEPLOY grepper='PickupPuppet'" >/tmp/PUPDEPLOY-20.log
echo "PUPDEPLOY: $?"
./reg-average.sh PickupPuppet /tmp/PUPDEPLOY-20.log
echo -n "Failed waits for a deployed file:"
ansible --forks 100 -i conf/20171214-bagl-puppet4.ini --user root -m shell -a 'grep "^fatal" "$( ls /root/out-*.log | sort | tail -n 1 )"' docker-hosts | grep ^fatal | wc -l
sleep 300

log "===== 30: $( date ) ====="
reg 6
sleep 100
ansible --forks 100 -i conf/20171214-bagl-puppet4.ini --user root -m shell -a "echo 30 >/root/container-used-count" docker-hosts >/dev/null
ansible-playbook --forks 100 -i conf/20171214-bagl-puppet4.ini playbooks/tests/registrations.yaml -e "size=30 tags=PUPDEPLOYSETUP update_used=false" >/tmp/PUPDEPLOYSETUP-30.log
echo "PUPDEPLOYSETUP: $?"
sleep 100
ansible-playbook --forks 100 -i conf/20171214-bagl-puppet4.ini playbooks/tests/registrations.yaml -e "size=30 tags=PUPDEPLOY grepper='PickupPuppet'" >/tmp/PUPDEPLOY-30.log
echo "PUPDEPLOY: $?"
./reg-average.sh PickupPuppet /tmp/PUPDEPLOY-30.log
echo -n "Failed waits for a deployed file:"
ansible --forks 100 -i conf/20171214-bagl-puppet4.ini --user root -m shell -a 'grep "^fatal" "$( ls /root/out-*.log | sort | tail -n 1 )"' docker-hosts | grep ^fatal | wc -l
sleep 300
