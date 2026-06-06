#!/bin/bash

source experiment/run-library.sh

branch="${PARAM_branch:-satcpt}"
inventory="${PARAM_inventory:-conf/contperf/inventory.${branch}.ini}"

ui_browser_browsers="${PARAM_ui_browser_browsers:-chromium,firefox}"
ui_browser_dataset_profile="${PARAM_ui_browser_dataset_profile:-medium}"
ui_browser_timeout_seconds="${PARAM_ui_browser_timeout_seconds:-60}"
ui_browser_verbose="${PARAM_ui_browser_verbose:-false}"
ui_browser_progress_log_file="${PARAM_ui_browser_progress_log_file:-/tmp/ui-browser-progress.log}"
ui_browser_capture_trace="${PARAM_ui_browser_capture_trace:-false}"
ui_browser_capture_workflow_traces="${PARAM_ui_browser_capture_workflow_traces:-false}"
ui_browser_diagnostic_workflows="${PARAM_ui_browser_diagnostic_workflows:-}"
ui_browser_browser_source="playwright-bundled"

opts="--forks 100 -i $inventory"
opts_adhoc="$opts"

section "UI browser test"
rm -f /tmp/status-data-ui-browser.json
skip_measurement='true' ap 10-webui-browser.log \
  -e "ui_browser_browsers='$ui_browser_browsers'" \
  -e "ui_browser_dataset_profile='$ui_browser_dataset_profile'" \
  -e "ui_browser_timeout_seconds='$ui_browser_timeout_seconds'" \
  -e "ui_browser_verbose='$ui_browser_verbose'" \
  -e "ui_browser_capture_trace='$ui_browser_capture_trace'" \
  -e "ui_browser_capture_workflow_traces='$ui_browser_capture_workflow_traces'" \
  -e "ui_browser_diagnostic_workflows='$ui_browser_diagnostic_workflows'" \
  -e "ui_browser_progress_log_file='$ui_browser_progress_log_file'" \
  -e "ui_browser_browser_source='$ui_browser_browser_source'" \
  playbooks/tests/webui-browser.yaml
STATUS_DATA_FILE=/tmp/status-data-ui-browser.json e "UIBrowserNavigation_browsers_${ui_browser_browsers//,/_}_roles_admin_viewer" "$logs/10-webui-browser.log"

junit_upload
