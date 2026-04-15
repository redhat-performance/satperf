#!/bin/bash

source experiment/run-library.sh

PARAM_manifest_exercise_runs="${PARAM_manifest_exercise_runs:-5}"  # lib default: 0

phases=(
    check_env
    prepare_rh_content
    create_lces
    create_bench_cvs_hammer
    get_base_content
    prepare_registrations
    concurrent_execution
    remote_execution
    misc
    backup
    cleanup
    sosreport
    junit_upload
)

for phase in "${phases[@]}"; do "$phase"; done
