#!/bin/sh

user=$1
pass=$2
task=$3
timeout=$4
log="$( mktemp )"

echo "DEBUG user: $user, pass: $pass, task: $task, timeout: $timeout, log: $log"

while true; do
    hammer --output yaml -u "$user" -p "$pass" task info --id "$task" >$log

    # Check if we are in correct state
    if grep --quiet '^State:\s\+stopped' $log &&
      grep --quiet '^Result:\s\+success' $log; then
        echo "INFO Task $task is in stopped/success state now"
        break
    fi

    # Check for timeout
    started_at="$( date -u -d "$( grep 'Started at:' $log | sed 's/^[^:]\+: //' )" +%s )"
    now="$( date -u +%s )"
    if (( $(( now - started_at )) > timeout )); then
        rm -f $log
        echo "TIMEOUT waiting on task $task" >&2
        exit 1
    fi

    # Check if we are in some incorrect state
    if grep --quiet '^State:\s\+stopped' $log &&
      grep --quiet '^Result:\s\+warning' $log; then
        rm -f $log
        echo "ERROR Task $task is in stopped/warning state" >&2
        exit 2
    fi

    # Wait and try again
    sleep 10
done

grep '^Started at:' $log | sed -e 's/^[^:]\+: //' -e 's/ UTC//'
grep '^Ended at:' $log | sed -e 's/^[^:]\+: //' -e 's/ UTC//'
awk '/^Duration:/ {print $NF}' $log | cut -d"'" -f2

rm -f $log
