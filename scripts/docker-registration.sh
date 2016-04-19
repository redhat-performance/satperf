#!/bin/sh

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
#       ssh root@$h 'for i in `seq 250`; do mkdir /tmp/yum-cache-$i/; docker run -d -v /tmp/yum-cache-$i/:/var/cache/yum/ r7perfsat; done' &
#   done
#
#   Get IPs of all the contaiers
#   # for h in docker1 docker2 docker3 docker4 docker5; do
#       ssh root@$h 'for c in $(docker ps -q); do docker inspect $c | python -c "import json,sys;obj=json.load(sys.stdin);print obj[0][\"Id\"], obj[0][\"NetworkSettings\"][\"IPAddress\"]"; done'
#   done >container-ips


# Some variables
satellite_ip=172.17.50.5
capsule_ip=172.17.50.5
batch=100
cleanup_sequence="clear-tools; clear-results; kill-tools; echo 3 > /proc/sys/vm/drop_caches;"
ansible_failed_re="^[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+ | FAILED | rc=[1-9][0-9]* | "
uuid_re="[a-f0-9]\{8\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{12\}"
if [ "$satellite_ip" -eq "$capsule_ip" ]; then
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
        subscription-manager clean
    - shell:
        rm -rf /var/cache/yum/*
    - shell:
        rpm -Uvh http://$capsule_ip/pub/katello-ca-consumer-latest.noarch.rpm
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

# Give Satellite some rest after previous round, do some
# Satellite's/Capsule's caches cleanup, restart measurement
log "Sleeping"
sleep 600
ssh root@$satellite_ip "$cleanup_sequence" \
    || warn "Cleanup seqence on '$satellite_ip' failed. Ignoring."
if [[ $satellite_ip != $capsule_ip ]]; then
    ssh root@$capsule_ip "$cleanup_sequence" \
        || warn "Cleanup seqence on '$capsule_ip' failed. Ignoring."
fi
sleep 60

# Select container IPs we are going to work with
list=$( mktemp )
cut -d ' ' -f 2 /root/container-ips \
    | sort --random-sort \
    | head -n $batch > $list
[[ $( wc -l $list | cut -d ' ' -f 1 ) -ne $batch ]] \
    && die "Was not able to determine IPs to use"

# Configure container
log=$( mktemp )
ansible-playbook -i $list --forks 100 setup.yaml &>$log \
    && log "Setup passed (full log in '$log')"
    || die "Setup failed (full log in '$log')"

# Finally schedule registration
stdout=$( mktemp )
stderr=$( mktemp )
log "Starting now (stdout: '$stdout', stderr: '$stderr')"
start=$( date +%s )
ansible all --forks $batch --one-line -u root -i $list -m shell -a "subscription-manager register --org=Default_Organization --environment=Library --username admin --password changeme --auto-attach --force" >$stdout 2>$stderr
rc=$?
end=$( date +%s )

# Report results
log "Finished now (elapsed $( expr $end - $start ) seconds)"
[[ $( wc -l $stderr | cut -d ' ' -f 1 ) -ne 0 ]] \
    && die "StdErr log '$stderr' should be empty, but it is not"
if [[ $( grep "$ansible_failed_re" $stdout | wc -l | cut -d ' ' -f 1 ) -eq 0 ]]; then
    log "No errors encountered here (full log in '$stdout')"
else
    log "Errors encountered were (full log in '$stdout'):"
    grep "$ansible_failed_re" $stdout | sed "s/$ansible_failed_re//" | sed "s/$uuid_re/<uuid>/" | sort | uniq -c
fi
