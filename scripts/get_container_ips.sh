#!/bin/bash

dockers="docker60 docker61 docker62"

for h in $dockers; do
	ssh root@$h 'for c in $(docker ps -q); do docker inspect $c | python -c "import json,sys;obj=json.load(sys.stdin);print obj[0][\"Id\"], obj[0][\"NetworkSettings\"][\"IPAddress\"]"; done'
done >/root/container-ips
sort -R /root/container-ips >/root/container-ips.shuffled

