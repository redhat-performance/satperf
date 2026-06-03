#!/bin/bash

source experiment/run-library.sh

PARAM_manifest_exercise_runs="${PARAM_manifest_exercise_runs:-5}"  # lib default: 0

phases=(
    check_env
    create_lces_fam
    prepare_rh_content_fam
    get_base_content_fam
    create_bench_cvs_fam
    sync_extra_content
    incremental_cv_updates_fam
    concurrent_execution
    remote_execution_fam
    misc
    ui
    backup
    cleanup_fam
    sosreport
    junit_upload
)

for phase in "${phases[@]}"; do "$phase"; done
