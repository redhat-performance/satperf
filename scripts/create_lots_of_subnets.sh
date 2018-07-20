#!/bin/sh

# Usage:
#   $locations_to - $locations_from = number of locations to create
#     One loc -> 100 domains -> 300 subnets
#     Recomendation: from 100 to 150
#
# # Create lots of locations/domains/subnets
# ansible -u root --private-key conf/contperf/id_rsa_perf -i conf/contperf/inventory.ini -m copy -a "src=scripts/create_lots_of_subnets.sh dest=/root/create_lots_of_subnets.sh force=yes" satellite6
# ansible -u root --private-key conf/contperf/id_rsa_perf -i conf/contperf/inventory.ini -m command -a "bash /root/create_lots_of_subnets.sh 100 150" satellite6
# ansible -u root --private-key conf/contperf/id_rsa_perf -i conf/contperf/inventory.ini -m shell -a "hammer -u admin -p changeme location list | wc -l; hammer -u admin -p changeme domain list | wc -l; hammer -u admin -p changeme subnet list | wc -l" satellite6

locations_from=$1
locations_to=$2

ip_a=0   # denotes location (will start from 100)
ip_b=0   # denotes domain
ip_c=0   # denotes subnet
ip_d=0
for ip_a in $( seq $locations_from $locations_to ); do
    location="Location $ip_a"
    hammer -u admin -p changeme location create --description "Description of $location" --name "$location"
    for ip_b in $( seq 1 100 ); do
        domain="loc${ip_a}dom${ip_b}.local"
        hammer -u admin -p changeme domain create --description "Description of $domain" --locations "$location" --name "$domain" --organizations 'Default Organization'
        for ip_c in $( seq 1 3 ); do
            from="$ip_a.$ip_b.$ip_c.$ip_d"
            to="$ip_a.$ip_b.$ip_c.255"
            hammer -u admin -p changeme subnet create --domains "$domain" --from "$from" --gateway "$from" --ipam DHCP --locations "$location" --organizations 'Default Organization' --mask 255.255.255.0 --name "Subnet $from-$to for $domain in $location" --network "$from" --to "$to" &
            # Limit number of background processes
            [ "$( jobs | wc -l | cut -d ' ' -f 1 )" -ge 10 ] && wait
        done
    done
done
