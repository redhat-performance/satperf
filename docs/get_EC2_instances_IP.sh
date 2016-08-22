#!/bin/bash

set -e

user_interrupt(){
    echo -e "\n\nKeyboard Interrupt detected."
    exit 1
}

trap user_interrupt SIGINT
trap user_interrupt SIGTSTP

[ $# = 0 ] && {
    echo -e "\nUsage: ./get_EC2_instances_IP.sh <keyword>\n"
    echo -e "\t<keyword> supports simple wildcard queries like: sat-*, *satellite*, .."
    echo -e "\nExample: \n$ ./get_EC2_instances_IP.sh sat-*capsule*"
    echo -e "..\nsat-capsule20\nsat-NG-capsule1\nsat-capsule16\n.."
    exit -1
}

keyword=$1

echo "Fetching currently running instance [ID, IP]s for 'tag:Name $keyword"

aws ec2 describe-instances --output text --query 'Reservations[].Instances[].[PublicIpAddress,Tags[0].Value]' --filters "Name=tag:Name,Values=$keyword" "Name=instance-state-name,Values=running" | sort > ec2_ips.txt

echo "...saved to ec2_ips.txt"

# filtered=$1
# keyword=$2



# # old method
# # aws ec2 describe-tags | grep sat- | awk '{print $4" "$6" "$8}' | grep i- > ec2_temp_data.txt

# # better method
# aws ec2 describe-tags --output text --query 'Tags[].Value' --filters Name=tag:Name,Values=$filtered | sed -e 's/\s\+/\n/g' > ec2_temp_data.txt


# echo "...saved to ec2_temp_data.txt"
# echo
# echo "Note: Not all related ID'ed instanced might be up and running."
# echo "To check status of an instance, use: aws ec2 describe-instance-status [ instance ID,(s) ..]"
# echo
# echo "...filter IDs for $keyword"

# egrep '^.*'$keyword'[0-9]*$' ec2_temp_data.txt | awk '{print $1}' > ec2_instance.$keyword.ids.txt

# echo "...saved to ec2_instance.$keyword.ids.txt"
# echo "...getting IPs"

# # old method
# # aws ec2 describe-instances --instance-ids $(cat ec2_instance.$keyword.ids.txt) | grep PublicIpAddress | awk '{print $(NF-1)}' > ec2_IP_Addresses.$keyword.instance.txt

# # better method
# aws ec2 describe-instances --instance-ids  $(cat ec2_instance.$keyword.ids.txt) --output text --query 'Reservations[].Instances[].PublicIpAddress' |  sed -e 's/\s\+/\n/g'  > ec2_IP_Addresses.$keyword.instance.txt

# # maybe useful later: tr " " "\n"

# echo "...saved to ec2_IP_Addresses.$keyword.instance.txt"
