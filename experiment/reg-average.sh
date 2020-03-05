#!/bin/sh

# When you capture playbooks/tests/registrations.yaml ouput into log file,
# this then counts aferage registration duration form the log
#
# sleep 120; ansible-playbook --forks 100 -i conf/20170625-gprfc019.ini playbooks/tests/registrations.yaml -e size=5 >reg-05.log; sleep 100; ansible-playbook --forks 100 -i conf/20170625-gprfc019.ini playbooks/tests/registrations.yaml -e size=10 >reg-10.log; sleep 100; ansible-playbook --forks 100 -i conf/20170625-gprfc019.ini playbooks/tests/registrations.yaml -e size=15 >reg-15.log ; sleep 100; ansible-playbook --forks 100 -i conf/20170625-gprfc019.ini playbooks/tests/registrations.yaml -e size=20 >reg-20.log

set -e

# What to grep for
matcher=$1
shift

begin_min=''
end_max=''

export IFS=$'\n'
for f in $@; do
    # Hardcoded to show registration start and end date
    grep -A 1 '^TASK \[Run clients.yaml' $f | tail -n 1
    grep -A 1 '^TASK \[Initialize an empty list for registration times' $f | tail -n 1
    # Count average for given matcher
    duration=0
    count=0
    for row in $( grep "\"$matcher " $f | sed "s/^.*\(\"$matcher.*\"\).*$/\1/" | cut -d '"' -f 2 ); do
        begin=$( date --utc -d "$( echo "$row" | cut -d ' ' -f 2,3 )" +%s )
        if [ -z "$begin_min" -o "$begin" -lt "0$begin_min" ]; then
            begin_min=$begin
        fi
        end=$( date --utc -d "$( echo "$row" | cut -d ' ' -f 5,6 )" +%s )
        if [ -z "$end_max" -o "$end" -gt "0$end_max" ]; then
            end_max=$end
        fi
        [ "$( expr $end - $begin )" -lt 50 ] \
          && echo "WARNING: On '$row', it took suspiciously little ($( expr $end - $begin ) seconds)"
        let duration+=$( expr $end - $begin )
        let count+=1
    done
    echo "min in $f: $begin_min"
    echo "max in $f: $end_max"
    echo "$matcher in $f: $duration / $count = $( echo "scale=2; $duration / $count" | bc )"
done
