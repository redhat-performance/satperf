cut -d ' ' -f 2 /root/container-ips.shuffled | head -n 150 | tail -n 25 >clients.ini
ansible-playbook -f25 -i clients.ini clients.yaml

