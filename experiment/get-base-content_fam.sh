#!/bin/bash

source experiment/run-library.sh

# Overrides that differ from function defaults
PARAM_lces="${PARAM_lces:-Test}"                # lib default: "Test QA Pre Prod"
PARAM_rels="${PARAM_rels:-rhel8 rhel9 rhel10}"  # lib default includes rhel7

phases=(
    check_env
    create_lces_fam
    prepare_rh_content_fam
    get_base_content_fam
    sosreport
    junit_upload
)

for phase in "${phases[@]}"; do "$phase"; done
