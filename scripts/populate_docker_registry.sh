set -xe

repos=20
images=100

concurency=10
registry_host=${REGISTRY_HOST:-registry.example.com:5000}

function doit() {
    tag="$1"
    docker build -f populate_docker_registry-Containerfile . --tag $tag --no-cache --rm=true
    rc_build=$?
    docker push $tag
    rc_push=$?
    docker rmi $tag
    rc_rmi=$?
    echo "$( date -Ins ) $tag $rc_build $rc_push $rc_build" >>populate_docker_registry.log
}

for repo in $( seq $repos ); do
    for image in $( seq $images ); do
        doit "$registry_host/test_repo$repo:ver$image" &

        # If number of background processes raises to set concurency lvl,
        # block untill some process ends
        background=( $(jobs -p) )
        if (( ${#background[@]} == $concurency )); then
            new_background=( $(jobs -p) )
            while [ "${background[*]}" = "${new_background[*]}" ]; do
                new_background=( $(jobs -p) )
                sleep 1
            done
        fi
    done
done

wait
