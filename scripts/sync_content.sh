#!/bin/bash
if [ ! $# == 2 ]; then
    echo "Usage: ./sync_content.sh <num-repos> <test-name>"
    echo "Example: time ./sync_content.sh 2 testing-sat61gas2-005"
    exit
fi
numRepos=$1
testname=$2

echo "----------------------------------"
sleep 5
# Perform Sync and time results
for repoid in `seq 1 ${numRepos}`; do
    echo "[$(date -R)] Starting content Synchronize: ${numsync}"
    time hammer -u "${ADMIN_USER}" -p "${ADMIN_PASSWORD}" repository synchronize --id $repoid --organization="${ORG}"  2>&1 &
done
echo "[$(date -R)] Waiting for Sync repos"
wait
echo "[$(date -R)] Syncs finished"
echo "----------------------------------"
