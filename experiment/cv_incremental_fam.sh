#!/bin/bash

# Incremental CV update performance baseline (SAT-31208).
#
# Creates CV_IncrementalBench with BaseOS+AppStream for RHEL 7/8/9/10
# (~8 repos) plus an erratum inclusion filter, no dependency solving.
# Publishes, promotes, then runs N incremental updates adding errata
# to measure baseline timing.

source experiment/run-library.sh

unset skip_measurement
set +e

phases=(
    # create_lces_fam
    # prepare_rh_content_fam
    # get_base_content_fam
    incremental_cv_updates_fam
    sosreport
    junit_upload
)

for phase in "${phases[@]}"; do "$phase"; done
