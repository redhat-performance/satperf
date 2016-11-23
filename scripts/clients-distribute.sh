#!/bin/sh

set -x
set -e

function doit() {
  # $1 ... docker host
  # $2 ... capsule to use
  # $3 and rest ... parts to uncomment
  local out=$( mktemp -d )
  local host=$1; shift
  local capsule=$1; shift
  local opts="-e 's/###CAPSULE###/$capsule/g'"
  for part in $@; do
    opts="$opts -e 's/###$part###//g'"
  done
  echo "sed $opts"
  eval sed $opts scripts/clients-source.yaml >$out/clients.yaml
  scp -i conf/id_rsa_perf conf/id_rsa_perf $out/clients.yaml root@$host:/root/ &
}

#doit <hostname> server PUPDEPLOY
doit perf112-vm2-docker.example.com root@perf112-vm1-capsule.example.com REG KAT

wait
