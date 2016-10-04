#!/bin/sh

set -e
#set -x

wd=$( pwd )
data=$( mktemp -d )
echo "DATA: $data"

function doit() {
  host=$1
  d=$( mktemp -d )
  scp -i conf/id_rsa_perf root@$host:/root/latest-out-puppetdeploy-*.log $d/
  cp $( ls $d/*.log | sort | tail -n 1 ) $data/$( echo $host | sed 's/[^a-z0-9-]/_/g' ).log
}

#doit <host> &
:wait

###data=/tmp/tmp.Av5MuHJI6j
function parse_dur() {
  export IFS=$'\x0A'$'\x0D'
  metric="$1"
  file="$2"
  if [ ! -r "$file" ]; then
    echo "ERROR: File '$file' can not be read (metric '$metric')" >&2
    return 1
  fi
  count=0
  sum=0
  for row in $( grep "\"msg\": \"$metric " "$file" ); do
    start=$( echo "$row" | sed "s/.*$metric \(.*\) to.*/\1/" )
    end=$( echo "$row" | sed "s/.*to \(.*\)\"$/\1/" )
    duration=$( expr $( date -d "$end" +%s ) - $( date -d "$start" +%s ) )
    ###echo "$start ... $end => $duration"
    let count+=1
    let sum+=$duration
  done
  echo "$file: $sum / $count = $( echo "scale=3; $sum / $count" | bc )"
}

tot_num=0
tot_dur=0
for i in $( seq 11 34 ); do
  tmp=$( mktemp )
  file="$data/ip-10-1-$i-0_us-west-2_compute_internal.log"
  parse_dur "PickupPuppet" "$file" | tee $tmp
  dur=$( cut -d ' ' -f 2 $tmp )
  num=$( cut -d ' ' -f 4 $tmp )
  let tot_num+=$num
  let tot_dur+=$dur
done
echo "TOTAL: $tot_dur / $tot_num = $( echo "scale=3; $tot_dur / $tot_num" | bc )"
