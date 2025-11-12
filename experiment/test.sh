#!/bin/bash

source experiment/run-library.sh


section 'Checking environment'
generic_environment_check false
# unset skip_measurement
# set +e


junit_upload
