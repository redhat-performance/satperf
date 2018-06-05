#!/bin/sh

RECORDER_URL="$( echo "$1" | sed 's|/*$||' )"   # URL of a recorder server, e.g. http://recorder.example.com:5000/
LOGS_DIR_P="$2"   # Directory with logs from `./run-puppet-workload.sh`
LOGS_DIR_B="$3"   # Directory with logs from `./run-bench.sh`

# FIXME: we are determining this only once, in second dir it might come from different satellite, but eventually we will merge these two I hope
# Determine satellite's hostname
sat_hostname=$( tail -n 1 $LOGS_DIR_P/info-hostname.log )
# Determine satellite's "satellite" package version
sat_ver=$( grep '^satellite-[0-9]' $LOGS_DIR_P/info-rpm-qa.log )

# Find all invocations of PuppetOne and PuppetBunch workload
for grepper in "PuppetOne" "PuppetBunch"; do
    for line in $( grep -n "/[0-9]\+-$grepper.log," "$LOGS_DIR_P/measurement.log" | cut -d ':' -f 1 ); do
        # Sum of the exit codes of commands before us
        score=$( head -n $( expr $line - 1 ) $LOGS_DIR_P/measurement.log | cut -d ',' -f 3 | paste -sd+ | bc )
        # Number of containers involved
        number=$( basename $( head -n $line $LOGS_DIR_P/measurement.log | tail -n 1 | cut -d ',' -f 2 ) | cut -d '-' -f 1 )

        # Data
        tmp=$( mktemp )
        ./reg-average.sh RegisterPuppet $LOGS_DIR_P/$number-$grepper.log 2>/dev/null | tail -n 1 >$tmp
        dataA1=$( cut -d ' ' -f 8 $tmp )
        dataA2=$( cut -d ' ' -f 6 $tmp )
        ./reg-average.sh SetupPuppet $LOGS_DIR_P/$number-$grepper.log 2>/dev/null | tail -n 1 >$tmp
        dataB1=$( cut -d ' ' -f 8 $tmp )
        dataB2=$( cut -d ' ' -f 6 $tmp )
        ./reg-average.sh PickupPuppet $LOGS_DIR_P/$number-$grepper.log 2>/dev/null | tail -n 1 >$tmp
        dataC1=$( cut -d ' ' -f 8 $tmp )
        dataC2=$( cut -d ' ' -f 6 $tmp )

        curl -X PUT "$RECORDER_URL/Sat6ContPerf/1/1/$grepper/$sat_hostname/$sat_ver/$score/$number/${dataA1:--}/${dataA2:--}/${dataB1:--}/${dataB2:--}/${dataC1:--}/${dataC2:--}"
    done
done

function put_average() {
    action="$1"
    grepper="$2"
    sum=0
    count=0
    for line in $( grep -n "$grepper" $LOGS_DIR_B/measurement.log | cut -d ":" -f 1 ); do
        row=$( head -n $line $LOGS_DIR_B/measurement.log | tail -n 1 )
        score=$( head -n $line $LOGS_DIR_P/measurement.log | cut -d ',' -f 3 | paste -sd+ | bc )
        beginning=$( echo "$row" | cut -d ',' -f '4' )
        finish=$( echo "$row" | cut -d ',' -f '5' )
        let sum+=$( expr $finish - $beginning )
        let count+=1
    done
    average=$( echo "scale=3; $sum / $count" | bc )
    curl -X PUT "$RECORDER_URL/Sat6ContPerf/1/1/$action/$sat_hostname/$sat_ver/$score/$average"
}

put_average "ManifestUpload" "01-manifest-upload-[0-9]\+.log"
put_average "SyncRHEL7immediate" "12-repo-sync-rhel7.log"
put_average "SyncRHEL6ondemand" "12-repo-sync-rhel6.log"
put_average "SyncRHEL7Optionalondemand" "12-repo-sync-rhel7optional.log"
put_average "PublishBigCV" "21-cv-all-publish.log"
put_average "PromoteBigCV" "23-cv-all-promote-[0-9]\+.log"
put_average "PublishSmallerFilteredCV" "33-cv-filtered-publish.log"
put_average "RegisterBunchOfContainers" "44-register-[0-9]\+.log"   # TODO: Also record how many passed/failed
put_average "ReXDateOnAll" "52-rex-date.log"   # TODO: Make sure we indicate on how much contaiers this ran
put_average "ReXRHSMUpdateOnAll" "53-rex-sm-facts-update.log"
