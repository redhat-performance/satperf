#!/bin/bash
if [ ! $# == 2 ]; then
    echo "Usage: ./sync-capsule.sh <num-capsules> <test-name>"
    echo "Example: time ./sync-capsule.sh 2 testing-sat61gas2-005"
    exit
fi
numcapsules=$1
testname=$2

echo "----------------------------------"
sleep 5
# Perform Sync and time results
for numcap in `seq 1 ${numcapsules}`; do
    capid=`expr ${numcap} + 1`
    echo "[$(date -R)] Starting Capsule Synchronize: ${numcap}"
    time hammer -u admin -p changeme capsule content synchronize --id ${capid} >> ${testname}.${capid} 2>&1  &
done
echo "[$(date -R)] Waiting for Sync to finish on Capsules"
wait
echo "[$(date -R)] Syncs finished on Capsules"
sleep 5
for numcap in `seq 1 ${numcapsules}`; do
    capid=`expr ${numcap} + 1`
    echo "[$(date -R)] SCP sync latency to ."
    echo "[$(date -R)] Real Timing:"
    tail -n 3 ${testname}.${capid}  | awk '{split($2, mtos,"m");split(mtos[2], seconds, "s");  total = (mtos[1] * 60) + seconds[1]; if (total != 0) {print $1 ", " total }}'
done
echo "----------------------------------"
