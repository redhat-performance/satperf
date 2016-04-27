#!/bin/bash

# This script is supposed to register containers, for example here we register
# 500 of containers in 10 bunches of 50 concurrent registrations:
#
#   # for i in $( seq 0 9 ); do
#       ./docker-registration.sh 50 $i sequence
#       sleep 60
#   done

# Some variables
satellite_ip=172.17.50.5
capsule_ip=172.17.50.5
batch=${1:-100}   # how many systems to use
offset=${2:0}   # how many $batch-es from start of the file to skipp (only for "sequence" queue type)
queue=${3:-random}   # how to use systems we will work with?
                     #   random ... choos randomly
                     #   sequence ... choose from start (controled by $offset and $batch)
cleanup_sequence="clear-tools; clear-results; kill-tools; echo 3 > /proc/sys/vm/drop_caches;"
if [[ $satellite_ip = $capsule_ip ]]; then
    is_capsule=false
else
    is_capsule=true
fi

# Source library
source lib.sh

# We will use these ansible scripts
cat >setup.yaml <<EOF
- hosts: all
  remote_user: root
  tasks:
    - shell:
        if [ -d /etc/rhsm-host ]; then mv /etc/rhsm-host{,.ORIG}; else true; fi
    - shell:
        if [ -d /etc/pki/entitlement-host ]; then mv /etc/pki/entitlement-host{,.ORIG}; else true; fi
    - shell:
        rpm -qa | grep katello-ca-consumer && yum --disablerepo=\* -y remove katello-ca-consumer-\* || true
    - shell:
        rpm -Uvh http://$capsule_ip/pub/katello-ca-consumer-latest.noarch.rpm
EOF
cat >unregister.yaml <<EOF
- hosts: all
  remote_user: root
  tasks:
    - shell:
        subscription-manager unregister
EOF
cat >cleanup.yaml <<EOF
- hosts: all
  remote_user: root
  tasks:
    - shell:
        subscription-manager clean
    - shell:
        rm -rf /var/cache/yum/*
    # TODO: stop and uninstall katello-agent and gofferd
EOF


#### Give Satellite some rest after previous round, do some
#### Satellite's/Capsule's caches cleanup, restart measurement
###log "Sleeping"
###sleep 600
###ssh root@$satellite_ip "$cleanup_sequence" \
###    || warn "Cleanup seqence on '$satellite_ip' failed. Ignoring."
###if [[ $satellite_ip != $capsule_ip ]]; then
###    ssh root@$capsule_ip "$cleanup_sequence" \
###        || warn "Cleanup seqence on '$capsule_ip' failed. Ignoring."
###fi
###sleep 60

# Select container IPs we are going to work with
list=$( mktemp )
get_list $list $queue $batch $offset

# Prepare container for registration
ansible_playbook setup.yaml
ansible_playbook cleanup.yaml

# Finally schedule registration
stdout=$( mktemp )
stderr=$( mktemp )
log "Starting now (stdout: '$stdout', stderr: '$stderr')"
start=$( date +%s )
# Note that on Ansible 2.0, you might run into:
#   https://github.com/ansible/ansible/issues/13862
ansible all --forks $batch --one-line -u root -i $list -m shell -a "subscription-manager register --org Default_Organization --environment Library --username admin --password changeme --auto-attach --force" >$stdout 2>$stderr
rc=$?
end=$( date +%s )
log "Finished now (elapsed $( expr $end - $start ) seconds; exit code was $rc)"

# Report results
[[ $( wc -l $stderr | cut -d ' ' -f 1 ) -ne 0 ]] \
    && die "StdErr log '$stderr' should be empty, but it is not"
ansible_errors_histogram $stdout

#### Do some cleanup now
###ansible_playbook unregister.yaml
###ansible_playbook cleanup.yaml
