#!/bin/bash

# This expects you have lots of containers available and their IPs in file
# container-ips which have format:
#
#   # head -n 3 container-ips
#   a6ccc312d286771261cb337504fd214f0cafe74dad39fa0339874a6fcf6d9360 172.1.0.249
#   3cacfc995a6c962a1ac0943983abdb321608219cfb82e35df8ba7de43d5dfc39 172.1.0.248
#   467187bc9bd0014b40ad6f30b00d2e2a39480ff24cf96069c1fe6e9062fcb75f 172.1.0.247
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


# Some variables
satellite_ip=172.17.50.5
capsule_ip=172.17.50.5
batch=${1:-100}   # how many systems to use
offset=${2:0}   # how many $batch-es from start of the file to skipp (only for "sequence" queue type)
queue=${3:-random}   # how to use systems we will work with?
                     #   random ... choos randomly
                     #   sequence ... choose from start (controled by $offset and $batch)
cleanup_sequence="clear-tools; clear-results; kill-tools; echo 3 > /proc/sys/vm/drop_caches;"
ansible_failed_re="^[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+ | FAILED"   # Ansible 2.0 and 1.9 differs here
uuid_re="[a-f0-9]\{8\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{12\}"
if [[ $satellite_ip = $capsule_ip ]]; then
    is_capsule=false
else
    is_capsule=true
fi


# We will use this ansible script
cat >setup.yaml <<EOF
- hosts: all
  remote_user: root
  tasks:
    - shell:
        if [ -d /etc/rhsm-host ]; then mv /etc/rhsm-host{,.ORIG}; else true; fi
    - shell:
        if [ -d /etc/pki/entitlement-host ]; then mv /etc/pki/entitlement-host{,.ORIG}; else true; fi
    - shell:
        yum -y remove katello-ca-consumer-\*
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

function log() {
    echo "[$(date)]: $*"
}

function warn() {
    log "WARN: $*" >&2
}

function die() {
    log "ERROR: $*" >&2
    exit 1
}


log "RUNNING BATCH OF $batch REGISTRATIONS"

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
case $queue in
    random)
        cut -d ' ' -f 2 /root/container-ips \
            | sort --random-sort \
            | head -n $batch > $list
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
    ;;
    *)
        die "Unknown queue type '$queue'"
    ;;
esac
[[ $( wc -l $list | cut -d ' ' -f 1 ) -ne $batch ]] \
    && die "Was not able to determine IPs to use (see '$list')"

function ansible_playbook() {
    local playbook=$1
    local log=$( mktemp )
    ansible-playbook -i $list --forks 50 $playbook &>$log \
        && log "$playbook passed (full log in '$log')" \
        || die "$playbook failed (full log in '$log')"
}

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
if [[ $( grep "$ansible_failed_re" $stdout | wc -l | cut -d ' ' -f 1 ) -eq 0 ]]; then
    log "No errors encountered here (full log in '$stdout')"
    grep "FAILED" $stdout || true   # just to be sure there were really no failures
else
    log "Errors encountered were (full log in '$stdout'):"
    grep "$ansible_failed_re" $stdout | sed "s/$ansible_failed_re//" | sed "s/$uuid_re/<uuid>/" | sort | uniq -c
fi

#### Do some cleanup now
###ansible_playbook unregister.yaml
###ansible_playbook cleanup.yaml
