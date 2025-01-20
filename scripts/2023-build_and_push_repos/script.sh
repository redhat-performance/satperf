#!/bin/bash -ex

for r in $( seq 10000 ); do
    ./ibmcloud login --apikey "$IBM_API_KEY"
    repo="repo$r"
    rm -rf "$repo"
    echo "$( date --utc -Ins ) $repo Building packages"
    python script.py $r >>LOG
    echo "$( date --utc -Ins ) $repo Creating repodata"
    createrepo_c $repo >>LOG
    echo "$( date --utc -Ins ) $repo Pushing content"
    for f in $( find $repo -type f ); do
        ./ibmcloud cos upload --bucket satellitetestrepos --region us-east --key "$f" --file "$f" >>LOG
    done
    echo "$( date --utc -Ins ) $repo Done"
done

