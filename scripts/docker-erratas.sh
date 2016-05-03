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
satellite_ip=192.168.122.10

# Source library
source lib.sh

# We will use these ansible scripts
cat >setup.yaml <<EOF
- hosts: all
  remote_user: root
  tasks:
      # Taken from http://stackoverflow.com/questions/32896877/is-it-possible-to-catch-and-handle-ssh-connection-errors-in-ansible
    - name: "Wait for machine to be available"
      local_action: wait_for
        host="{{ ansible_ssh_host }}"
        port=22
        delay=5
        timeout=300
        state=started
    - get_url:
        url=http://$satellite_ip/pub/katello-server-ca.crt
        dest=/etc/rhsm/ca/katello-default-ca.pem
        force=yes
    - get_url:
        url=http://$satellite_ip/pub/katello-server-ca.crt
        dest=/etc/rhsm/ca/katello-server-ca.pem
        force=yes
    - name: "Enable required repos"
      shell: |
        subscription-manager repos --enable rhel-7-server-rh-common-rpms
        subscription-manager attach --pool 8a909d8b545fbc2d01546006d67a0182 --pool 8a909d8b54625509015475d5542655dc
        subscription-manager repos --enable Default_Organization_Stuff_from_CI_server_Tools_RHEL7_x86_64
    - name: "Install katello-agent"
      action:
        yum
          name=katello-agent
          state=latest
      register: installed
      until: "installed.rc != 0"
      retries: 10
      delay: 10
    - name: "Make sure we have at least one errata applicable"
      command:
        yum -y downgrade sos-3.2-15.el7_1.5.noarch
    - name: "Start journald"
      shell:
        pgrep --full '/usr/lib/systemd/systemd-journald' || /usr/lib/systemd/systemd-journald &
    - name: "(Re)start goferd"
      shell: |
        pgrep --full '/usr/bin/goferd' && pkill --full '/usr/bin/goferd'
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
###[[ $( wc -l $stderr | cut -d ' ' -f 1 ) -ne 0 ]] \
###    && die "StdErr log '$stderr' should be empty, but it is not"
###ansible_errors_histogram $stdout

#### Do some cleanup now
###ansible_playbook cleanup.yaml
