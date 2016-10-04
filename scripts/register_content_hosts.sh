#!/bin/bash

dockers="docker60 docker61 docker62"
for h in $dockers; do
	echo "=== $h ==="
	ssh root@$h 'for i in `seq 250`; do [ -d /tmp/yum-cache-$i/ ] || mkdir /tmp/yum-cache-$i/; rm -rf /tmp/yum-cache-$i/*; docker run -h `hostname -s`container$i.example.com -d -v /tmp/yum-cache-$i/:/var/cache/yum/ r7perfsat; done' &
done


