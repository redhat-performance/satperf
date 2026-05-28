#!/bin/bash

# Rolling content view performance scaling test (SAT-36759).
#
# Measures sync time degradation as rolling CVs are added in batches,
# using custom yum repos. Requires Satellite >= 6.18.
#
# Creates N rolling CVs in batches of B, re-syncing after each batch
# to build a sync_time = f(rolling_cv_count) curve.

source experiment/run-library.sh

unset skip_measurement
set +e

phases=(
    setup_rolling_repos_fam
    rolling_cv_scaling_fam
    sosreport
    junit_upload
)

for phase in "${phases[@]}"; do "$phase"; done
