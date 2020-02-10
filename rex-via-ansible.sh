#!/bin/bash

h 52-rex-date.log "job-invocation create --inputs \"command='date'\" --job-template 'Run Command - Ansible Default' --search-query 'name ~ container'"
s $wait_interval
