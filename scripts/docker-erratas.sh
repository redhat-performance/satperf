#!/bin/bash

# This script is supposed to setup katello-agent on registered container
# and apply one errata - e.g. on 500 containers in 10 bunches of
# 50 containers:
#
#   # for i in $( seq 0 9 ); do
#       ./docker-erratas.sh 50 $i sequence
#       sleep 60
#   done

# Some variables
batch=${1:-100}   # how many systems to use
offset=${2:0}   # how many $batch-es from start of the file to skipp (only for "sequence" queue type)
queue=${3:-sequence}   # how to use systems we will work with?
                     #   random ... choos randomly
                     #   sequence ... choose from start (controled by $offset and $batch)

# Source library
source lib.sh

# We will use these ansible scripts
cat >setup.yaml <<EOF
- hosts: all
  remote_user: root
  tasks:
    - shell: |
        subscription-manager repos --enable rhel-7-server-rh-common-rpms
        subscription-manager attach --pool 8a909d8b5451f1d7015457077aa54474
        subscription-manager repos --enable Default_Organization_Stuff_from_CI_server_Tools_RHEL7_x86_64
    - yum:
        name=katello-agent
        state=latest
    - shell:
        /usr/lib/systemd/systemd-journald &
    - shell:
        /usr/bin/goferd --foreground
EOF
cat >uninstall.yaml <<EOF
- hosts: all
  remote_user: root
  tasks:
    - ping
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

#### Finally schedule registration
###stdout=$( mktemp )
###stderr=$( mktemp )
###log "Starting now (stdout: '$stdout', stderr: '$stderr')"
###start=$( date +%s )
#### Note that on Ansible 2.0, you might run into:
####   https://github.com/ansible/ansible/issues/13862
###ansible all --forks $batch --one-line -u root -i $list -m shell -a "subscription-manager register --org Default_Organization --environment Library --username admin --password changeme --auto-attach --force" >$stdout 2>$stderr
###rc=$?
###end=$( date +%s )
###log "Finished now (elapsed $( expr $end - $start ) seconds; exit code was $rc)"
###
#### Report results
###ansible_errors_histogram $stdout

#### Do some cleanup now
###ansible_playbook cleanup.yaml
