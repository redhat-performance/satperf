#!/bin/bash

source experiment/run-library.sh

PARAM_lces="${PARAM_lces:-Test}"                # lib default: "Test QA Pre Prod"
PARAM_rels="${PARAM_rels:-rhel8 rhel9 rhel10}"  # lib default includes rhel7
PARAM_tasks_list="${PARAM_tasks_list:-registration}"
PARAM_retry_failed="${PARAM_retry_failed:-false}"

phases=(
    check_env
    concurrent_execution
    sosreport
    junit_upload
)

for phase in "${phases[@]}"; do "$phase"; done
