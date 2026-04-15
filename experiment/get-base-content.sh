#!/bin/bash

source experiment/run-library.sh

PARAM_rels="${PARAM_rels:-rhel7 rhel8 rhel9 rhel10}"

phases=(
    check_env
    prepare_rh_content
    create_lces
    get_base_content
    sosreport
    junit_upload
)

for phase in "${phases[@]}"; do "$phase"; done
