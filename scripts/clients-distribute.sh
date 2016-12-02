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
###doit docker1.example.com  pman05.perf.lab.eng.bos.redhat.com REG KAT REM
doit docker2.example.com  pman05.perf.lab.eng.bos.redhat.com REG KAT REM
doit docker3.example.com  pman05.perf.lab.eng.bos.redhat.com REG KAT REM
doit docker4.example.com  pman05.perf.lab.eng.bos.redhat.com REG KAT REM
###doit docker5.example.com pman05.perf.lab.eng.bos.redhat.com REG KAT REM
doit docker6.example.com  pman05.perf.lab.eng.bos.redhat.com REG KAT REM
doit docker7.example.com  pman05.perf.lab.eng.bos.redhat.com REG KAT REM
doit docker8.example.com  pman05.perf.lab.eng.bos.redhat.com REG KAT REM
doit docker9.example.com  pman05.perf.lab.eng.bos.redhat.com REG KAT REM
doit docker10.example.com pman05.perf.lab.eng.bos.redhat.com REG KAT REM
doit docker11.example.com pman05.perf.lab.eng.bos.redhat.com REG KAT REM
doit docker12.example.com pman05.perf.lab.eng.bos.redhat.com REG KAT REM
doit docker13.example.com pman05.perf.lab.eng.bos.redhat.com REG KAT REM
doit docker14.example.com pman05.perf.lab.eng.bos.redhat.com REG KAT REM
doit docker15.example.com pman05.perf.lab.eng.bos.redhat.com REG KAT REM
doit docker16.example.com pman05.perf.lab.eng.bos.redhat.com REG KAT REM
doit docker17.example.com pman05.perf.lab.eng.bos.redhat.com REG KAT REM
#doit docker18.example.com pman05.perf.lab.eng.bos.redhat.com
#doit docker19.example.com pman05.perf.lab.eng.bos.redhat.com
#doit docker20.example.com pman05.perf.lab.eng.bos.redhat.com
#doit docker21.example.com pman05.perf.lab.eng.bos.redhat.com

wait
