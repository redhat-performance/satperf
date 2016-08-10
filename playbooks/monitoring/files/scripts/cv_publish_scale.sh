#!/bin/bash
echo "----------------------------------"
echo "[$(date -R)] content view publish starts"
for cvnum in `seq 1 $NUMCV`; do
#time hammer -u "${ADMIN_USER}" -p "${ADMIN_PASSWORD}" content-view publish --name=cv$cvnum  --organization="${ORG}" 2>&1 &
hammer -u "${ADMIN_USER}" -p "${ADMIN_PASSWORD}" content-view publish --name=cv$cvnum  --organization="${ORG}" --async
done
echo "[$(date -R)] Waiting for CV publishing to complete"
wait
echo "[$(date -R)] CV Publish finished"
echo 
