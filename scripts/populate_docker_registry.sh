set -e

repos=20
images=100

concurency=10
registry_host=${REGISTRY_HOST:-registry.example.com:5000}

function doit() {
    tag="$1"
    log="$( echo "$tag" | sed 's/[^a-zA-Z0-9-]/_/g' ).log"
    echo "DEBUG: Started build of $tag with log in $log"
    {
        docker build -f populate_docker_registry-Containerfile . --tag $tag --no-cache --rm=true
        rc_build=$?
        docker push $tag
        rc_push=$?
        docker rmi $tag
        rc_rmi=$?
    } >$log
    echo "$( date -Ins ) $tag $rc_build $rc_push $rc_build" >>aaa.log
}

for repo in $( seq $repos ); do
    for image in $( seq $images ); do
        doit "$registry_host/test_repo$repo:ver$image" &

        # If number of background processes raises to set concurency lvl,
        # block untill some process ends
        background=( $(jobs -p) )
        if (( ${#background[@]} >= $concurency )); then
            echo "DEBUG: Reached concurency level, waiting for some task to finish"
            new_background=( $(jobs -p) )
            while [ "${background[*]}" = "${new_background[*]}" ]; do
                echo "DEBUG: Waiting: ${new_background[*]}"
                new_background=( $(jobs -p) )
                sleep 1
            done
        fi
    done
done

echo "DEBUG: Waiting for ramaining tasks"
wait
