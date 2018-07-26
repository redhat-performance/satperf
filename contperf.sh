#!/bin/sh

set -x

ansible-playbook --skip-tags "clean_all" -i conf/contperf/inventory.ini playbooks/kvm-hosts/cleanup.yaml
ansible-playbook -i conf/contperf/inventory.ini playbooks/kvm-hosts/install-vms.yaml

ansible-playbook --skip-tags "satellite-populate,client-content" -i conf/contperf/inventory.ini playbooks/satellite/installation.yaml
ansible-playbook -i conf/contperf/inventory.ini playbooks/docker/docker-host.yaml playbooks/docker/docker-tierup.yaml

# Configure monitoring on a Satellite machine (Grafana is http://dhcp31-144.perf.lab.eng.bos.redhat.com:11202/)
cd ../satellite-monitoring/
ansible-playbook --private-key ../satellite-performance/conf/contperf/id_rsa_perf -i ../satellite-performance/conf/contperf/inventory.ini ansible/collectd-generic.yaml --tags "satellite6" -e "carbon_host=dhcp31-203.perf.lab.eng.bos.redhat.com carbon_port=2003"
cd -

./run-bench.sh
