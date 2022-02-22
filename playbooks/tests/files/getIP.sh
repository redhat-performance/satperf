#!/usr/bin/bash
for cn in $(docker ps | cut -d " " -f 1)
do
docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $cn >> cont.ini
done
