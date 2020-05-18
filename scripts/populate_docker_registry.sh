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
    echo "$( date -Ins ) $tag $rc_build $rc_push $rc_build" >>aaa.log
}

for repo in $( seq $repos ); do
    for image in $( seq $images ); do
        doit "$registry_host/test_repo$repo:ver$image" &

        # From https://stackoverflow.com/a/32464803/2229885
        # Check how many background jobs there are, and if it
        # is equal to the number of cores, wait for anyone to
        # finish before continuing.
        background=( $(jobs -p) )
        if (( ${#background[@]} == $concurency )); then
            wait -n   # wait for first to stop
        fi
    done
done

wait
