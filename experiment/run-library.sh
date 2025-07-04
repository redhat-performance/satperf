#!/bin/bash

set -o pipefail
###set -x
set -e


# We need to add an ID to run-bench runs to be able to filter out results from multiple runs. This ID will be appended as
# the last field of lines in measurement.log file.
# The ID should be passed as a argument to the run-bench.sh. If there is no argument passed, default ID will be
# generated based on the current date and time.
marker_date="$( date -u -Iseconds )"
[[ -n $marker ]] || marker="${1:-run-${marker_date}}"

branch="${PARAM_branch:-satcpt}"
sat_version="${PARAM_sat_version:-stream}"
inventory="${PARAM_inventory:-conf/contperf/inventory.${branch}.ini}"
content_host_base_image="${PARAM_content_host_base_image:-ubi-init-smallest-satellite_client}"

opts="${opts:-"--forks 100 -i $inventory"}"
opts_adhoc="${opts_adhoc:-$opts}"
logs=$marker
run_lib_dryrun=false

# Requirements check
#if ! type bc >/dev/null; then
#    echo "ERROR: bc not installed" >&2
#    exit 1
#fi
if ! type ansible >/dev/null; then
    echo "ERROR: ansible not installed" >&2
    exit 1
fi
# if ! type rpmdev-vercmp >/dev/null; then
#     echo "ERROR: rpmdev-vercmp (from rpmdevtools) not installed" >&2
#     exit 1
# fi

function _vercmp() {
    # Return values mimic `rpmdev-vercmp` ones
    if [[ "$1" == "$2" ]]; then
        return 0
    elif [[ "$1" == 'stream' ]]; then
        return 11
    elif [[ "$2" == 'stream' ]]; then
        return 12
    else
        ver1="$( echo "$1" | sed 's/^\(satellite\|katello\)-//' | sed 's/^\([^-]\+\)-.*$/\1/' )"
        ver2="$( echo "$2" | sed 's/^\(satellite\|katello\)-//' | sed 's/^\([^-]\+\)-.*$/\1/' )"

#         rpmdev-vercmp "$ver1" "$ver2"

        # FIXME: This parser sucks. Would be better to have rpmdev-vercmp once
        # CID-5112 is resolved
        # echo "Comparing $ver1 vs. $ver2"
        ver1_1="$( echo "$ver1" | cut -d '.' -f 1 )"
        ver1_2="$( echo "$ver1" | cut -d '.' -f 2 )"
        ver1_3="$( echo "$ver1" | cut -d '.' -f 3 )"
        vers1=( $ver1_1 $ver1_2 $ver1_3 )
        ver2_1="$( echo "$ver2" | cut -d '.' -f 1 )"
        ver2_2="$( echo "$ver2" | cut -d '.' -f 2 )"
        ver2_3="$( echo "$ver2" | cut -d '.' -f 3 )"
        vers2=( $ver2_1 $ver2_2 $ver2_3 )

        for i in 0 1 2; do
            sub_vers1="${vers1[$i]}"
            sub_vers2="${vers2[$i]}"
            # echo "Comparing item $sub_vers1 vs. $sub_vers2"
            if [[ "$sub_vers1" != 'stream' && "$sub_vers2" != 'stream' ]]; then
                if (( sub_vers1 > sub_vers2 )); then
                    return 11
                elif (( sub_vers1 < sub_vers2 )); then
                    return 12
                fi
            elif [[ "$sub_vers1" == 'stream' && "$sub_vers2" != 'stream' ]]; then
                return 11
            elif [[ "$sub_vers1" != 'stream' && "$sub_vers2" == 'stream' ]]; then
                return 12
            fi
        done
        return 0
    fi
}

function vercmp_gt() {
    # Check if first parameter is greater than second using version string comparision
    _vercmp "$1" "$2"
    local rc=$?
    (( rc == 11 )) && return 0 || return 1
}

function vercmp_ge() {
    # Check if first parameter is greater or equal than second using version string comparision
    _vercmp "$1" "$2"
    local rc=$?
    (( rc == 11 || rc == 0 )) && return 0 || return 1
}

function get_inventory_var() {
    local inventory_var=$1

    ansible $opts_adhoc \
      -m ansible.builtin.debug \
      -a "var=$inventory_var" \
      satellite6 |
      sed -E 's/.*[[:space:]]*=>[[:space:]]*\{/\{/' |
      jq -r --arg INVENTORY_VAR "$inventory_var" '.[$INVENTORY_VAR]'
}


foreman_username="$( get_inventory_var foreman_username )"
foreman_password="$( get_inventory_var foreman_password )"
hammer_opts="-u $foreman_username -p $foreman_password"


function measurement_add() {
    python3 -c "import csv; import sys; fp=open('$logs/measurement.log','a'); writer=csv.writer(fp); writer.writerow(sys.argv[1:]); fp.close()" "$@"
    if [[ "$skip_measurement" != 'true' ]]; then
        status_data_create "$@"
    fi
}

function measurement_row_field() {
    python3 -c "import csv; import sys; reader=csv.reader(sys.stdin); print list(reader)[0][int(sys.argv[1])-1]" $1
}

function generic_environment_check() {
    extended="${1:-true}"
    restarted="${2:-true}"
    wait_for_ping="${3:-false}"

    export skip_measurement=true

    as 00-info-rpm-qa.log \
      'rpm -qa | sort'

    as 00-info-hostname.log \
      'hostname'

    a 00-info-ip-a.log \
      -m ansible.builtin.shell \
      -a 'ip a' \
      satellite6,capsules,container_hosts

    a 00-check-ping-registration-target.log \
      -m ansible.builtin.shell \
      -a 'ping -c 10 {{ tests_registration_target }}' \
      container_hosts

    if $extended; then
        ap 00-remove-hosts-if-any.log \
          playbooks/satellite/satellite-remove-hosts.yaml

        number_container_hosts="$( ansible $opts_adhoc \
          --list-hosts \
          container_hosts 2>/dev/null |
          grep -cv '^  hosts' )"
        if (( number_container_hosts > 0 )); then
            ap 00-tierdown-containers.log \
              ansible-container-host-mgr/tierdown.yaml

            a 00-delete-private-connection.log \
              -m ansible.builtin.shell \
              -a 'nmcli con delete {{ private_nic }} 2>/dev/null; echo' \
              container_hosts

            ap 00-tierup-containers.log \
              -e "content_host_base_image='$content_host_base_image'" \
              ansible-container-host-mgr/tierup.yaml
        fi
    fi

    if $restarted; then
        as 00-satellite-drop-caches.log \
          'foreman-maintain service stop; sync; echo 3 > /proc/sys/vm/drop_caches; foreman-maintain service start'
    fi

    as 00-info-rpm-q-katello.log \
      'rpm -q katello'
    katello_rpm="$( tail -n 1 $logs/00-info-rpm-q-katello.log )"
    echo "$katello_rpm" | grep '^katello-[0-9]\.' # make sure it's been detected correctly

    as 00-info-rpm-q-satellite.log \
      'rpm -q satellite || true'
    satellite_rpm="$( tail -n 1 $logs/00-info-rpm-q-satellite.log )"

    log "katello_version = $katello_rpm"
    log "satellite_version = $satellite_rpm"

    if ! $wait_for_ping; then
        h 00-check-hammer-ping.log \
          'ping'
    else
        while true; do
            set +e

            h 00-check-hammer-ping.log \
              'ping' &&
              break

            set -e
        done
    fi

    unset skip_measurement

    set +e   # Quit "-e" mode as from now on failure is not fatal
}

function get_repo_id() {
    local organization=$1
    local product=$2
    local repo=$3
    local tmp="$( mktemp )"

    h_out "--output yaml repository info --organization '$organization' --product '$product' --name '$repo'" >"$tmp"
    grep '^I[Dd]:' "$tmp" | cut -d ' ' -f 2
    rm -f "$tmp"
}

function status_data_create() {
    # For every measurement, create new status data file, consult with
    # historical data if test result is PASS or FAIL, upload current result
    # to historical storage (ElasticSearch) and add test result to
    # junit.xml for further analysis.

    debug_log="$2.status_data_create_debug"
    (
    set -x

    [[ -n $PARAM_elasticsearch_host ]] || return 0

    if [ -z "$4" -o -z "$5" ]; then
        echo "WARNING: Either start '$4' or end '$5' timestamps are empty, not going to create status data" >&2
        return 1
    fi

    # Activate tools virtualenv
    source venv/bin/activate

    # Load variables
    sd_section="${SECTION:-default}"
    sd_cli=$1; shift
    sd_log="$1"; shift
    sd_rc=$1; shift
    if [[ "$1" =~ [[:digit:]]{4}-[[:digit:]]{2}-[[:digit:]]{2}T[[:digit:]]{2}:[[:digit:]]{2}:[[:digit:]]{2}.*\+[[:digit:]]{2}:[[:digit:]]{2} ]]; then
        sd_start=$1; shift
    else
        sd_start_seconds=$1; shift
        sd_start="$( date -u -Iseconds -d @$sd_start_seconds )"
    fi
    if [[ "$1" =~ [[:digit:]]{4}-[[:digit:]]{2}-[[:digit:]]{2}T[[:digit:]]{2}:[[:digit:]]{2}:[[:digit:]]{2}.*\+[[:digit:]]{2}:[[:digit:]]{2} ]]; then
        sd_end=$1; shift
    else
        sd_end_seconds=$1; shift
        sd_end="$( date -u -Iseconds -d @$sd_end_seconds )"
    fi
    if [[ "$1" =~ [[:digit:]]+\.[[:digit:]]{6} ]]; then
        sd_duration=$1; shift
    else
        sd_duration="$(( $( date -d @$sd_end_seconds +%s ) - $( date -d @$sd_start_seconds +%s ) ))"
    fi
    sd_kat_rpm=$1; shift
    [[ -n $sd_kat_rpm ]] ||
        sd_kat_rpm="$( ansible $opts_adhoc \
          -m ansible.builtin.shell \
          -a 'rpm -q katello' \
          satellite6 2>/dev/null |
          tail -n 1 )"
    sd_kat_ver_short="$( echo "$sd_kat_rpm" | sed 's#^\(katello-\)\(.*\)\(-.*$\)#\2#g' )"   # "katello-3.16.0-0.2.master.el7.noarch" -> "3.16.0"
    sd_kat_ver_y="$( echo "$sd_kat_ver_short" | awk -F'.' '{print $1"."$2}' )"
    sd_sat_rpm=$1; shift
    [[ -n $sd_sat_rpm ]] ||
        sd_sat_rpm="$( ansible $opts_adhoc \
          -m ansible.builtin.shell \
          -a 'rpm -q satellite' \
          satellite6 2>/dev/null |
          tail -n 1 )"
    sd_sat_ver_short="$( echo "$sd_sat_rpm" | sed 's#^\(satellite-\)\(.*\)\(-.*$\)#\2#g' )"   # "satellite-6.15.1-1.el8.noarch" -> "6.15.1"
    sd_sat_ver_y="$( echo "$sd_sat_ver_short" | awk -F'.' '{print $1"."$2}' )"
    sd_run=$1; shift
    sd_additional=$1

    # derive testcase name from log name which is descriptive
    if [[ "$sd_log" =~ \.json$ ]]; then
        sd_name="$( basename "$sd_log" .json )"
    elif [[ "$sd_log" =~ \.log$ ]]; then
        sd_name="$( basename "$sd_log" .log )"
    fi
    if [ -n "$STATUS_DATA_FILE" -a -f "$STATUS_DATA_FILE" ]; then
        sd_file="$STATUS_DATA_FILE"
    else
        sd_file="$sd_log.json"
        rm -f "$sd_file"
    fi
    if [ -n "$RDD_FILE" -a -f "$RDD_FILE" ]; then
        rdd_file="$RDD_FILE"
    else
        rdd_file="$sd_log.rdd.json"
        rm -f "$rdd_file"
    fi
    if [ -n "$PARAM_inventory" ]; then
        sd_hostname="$( ansible $opts_adhoc \
          --list-hosts \
          satellite6 2>/dev/null |
          tail -n 1 | sed -e 's/^\s\+//' -e 's/\s\+$//' -e 's/^ *//' )"
    fi
    workdir_url="${PARAM_workdir_url:-https://workdir-exporter.example.com/workspace}"
    sd_link="${workdir_url}/${JOB_NAME:-NA}/${sd_log}"

    # Create status data file
    set -x
    status_data.py --status-data-file "$sd_file" --set \
      "id=$sd_run" \
      "name=$sd_section/$sd_name" \
      "parameters.cli=$( echo "$sd_cli" | sed 's/=/__/g' )" \
      "parameters.katello_version=$sd_kat_rpm" \
      "parameters.katello_version-y-stream=$sd_kat_ver_y" \
      "parameters.version=$sd_sat_rpm" \
      "parameters.version-y-stream=$sd_sat_ver_y" \
      "parameters.run=$sd_run" \
      "parameters.hostname=$sd_hostname" \
      "results.log='$sd_log'" \
      "results.rc=$sd_rc" \
      "results.duration=$sd_duration" \
      "results.jenkins.build_url=${BUILD_URL:-NA}" \
      "results.jenkins.node_name=${NODE_NAME:-NA}" \
      "started=$sd_start" \
      "ended=$sd_end" \
      "golden=${GOLDEN:-false}" \
      $sd_additional
    set +x

    # Add monitoring data to the status data file (*.log.json)
    if [[ -n "$PARAM_grafana_host" ]] && [[ -n "$PARAM_cluster_read_config" ]]; then
        local grafana_nodes="$( ansible $opts_adhoc \
          --list-hosts \
          satellite6,capsules 2>/dev/null | \
          grep -v '^  hosts' | \
          sed -e 's/^\s\+//' -e 's/\s\+$//' | sed 's/\./_/g' )"

        for PARAM_grafana_node in $grafana_nodes; do
            set -x
            # `node_short` will be used as Jinja2 variable in `$PARAM_cluster_read_config`
            node_short="$( echo $PARAM_grafana_node | cut -d'_' -f1 )" status_data.py -d \
              --status-data-file "$sd_file" \
              --additional $PARAM_cluster_read_config \
              --monitoring-start $sd_start \
              --monitoring-end $sd_end \
              --grafana-host $PARAM_grafana_host \
              --grafana-port $PARAM_grafana_port \
              --grafana-prefix $PARAM_grafana_prefix \
              --grafana-datasource $PARAM_grafana_datasource \
              --grafana-interface $PARAM_grafana_interface \
              --grafana-token $PARAM_grafana_token \
              --grafana-node $PARAM_grafana_node
            set +x
        done
    fi

    # Only continue uploading results to ES and RP if `GOLDEN`
    [[ "$GOLDEN" == 'true' ]] || return 0

    # Based on historical data, determine result of this test
    sd_result_log="$( mktemp )"
    if [ "$sd_rc" -eq 0 -a -n "$PARAM_investigator_config" ]; then
        export sd_section
        export sd_name
        set +e
        set -x
        pass_or_fail.py \
          --config $PARAM_investigator_config \
          --current-file "$sd_file" 2>&1 | tee "$sd_result_log"
        pof_rc=$?
        set +x
        set -e
        if (( pof_rc == 0 )); then
            sd_result=PASS
        elif (( pof_rc == 1 )); then
            sd_result=FAIL
        else
            sd_result=ERROR
        fi
    else
        sd_result=ERROR
    fi

    # Add result to the status data so it is complete
    status_data.py --status-data-file "$sd_file" --set \
      "result=$sd_result"

    # Upload status data to ElasticSearch
    url="http://$PARAM_elasticsearch_host:$PARAM_elasticsearch_port/${PARAM_elasticsearch_index:-satellite_perf_index}/${PARAM_elasticsearch_mapping:-_doc}/"
    echo "INFO: POSTing '$sd_file' to '$url'"
    curl --silent \
      -X POST \
      -H 'Content-Type: application/json' \
      --data "@$sd_file" \
      $url |
      python3 -c "import sys, json; obj, pos = json.JSONDecoder().raw_decode(sys.stdin.read()); assert '_shards' in obj and  obj['_shards']['successful'] >= 1 and obj['_shards']['failed'] == 0, 'Failed to upload status data: %s' % obj"
    ###status_data.py --status-data-file $sd_file --info

    # Create "results-dashboard-data" data file
    if [[ "$sat_version" == 'stream' ]]; then
        sd_sat_release=stream
    else
        sd_sat_release="$( echo "$sd_sat_ver_short" | awk -F'.' '{print $1"."$2}' )"
    fi
    sd_sat_ver="$sd_sat_ver_short"
    set -x
    jq -n \
      --arg release $sd_sat_release \
      --arg version $sd_sat_ver \
      --arg date $sd_start \
      --arg link "$sd_link" \
      --arg result_id $sd_run \
      --arg test "$sd_name" \
      --arg result $sd_result \
      '{
        "group": "Core Platforms",
        "product": "Red Hat Satellite",
        "version": $version,
        "release": $release,
        "date": $date,
        "link": $link,
        "result_id": $result_id,
        "test": $test,
        "result": $result,
      }' >"$rdd_file"
    set +x

    # Upload status data to "results-dashboard-data" ElasticSearch
    url="http://${PARAM_elasticsearch_host}:${PARAM_elasticsearch_port}/results-dashboard-data/${PARAM_elasticsearch_mapping:-_doc}/"
    echo "INFO: POSTing results data to '$url'"
    curl --silent \
      -X POST \
      -H 'Content-Type: application/json' \
      --data "@$rdd_file" \
      $url |
      python3 -c "import sys, json; obj, pos = json.JSONDecoder().raw_decode(sys.stdin.read()); assert '_shards' in obj and  obj['_shards']['successful'] >= 1 and obj['_shards']['failed'] == 0, 'Failed to upload status data: %s' % obj"

    # Enhance log file
    tmp="$( mktemp )"
    echo "command: $sd_cli" >>"$tmp"
    echo "satellite version: $sd_sat_rpm" >>"$tmp"
    echo "katello version: $sd_kat_rpm" >>"$tmp"
    echo "hostname: $sd_hostname" >>"$tmp"
    if [[ "$sd_result" != 'ERROR' ]]; then
        echo 'result determination log:' >>"$tmp"
        cat "$sd_result_log" >>"$tmp"
    fi
    echo >>"$tmp"
    cat "$sd_log" >>"$tmp"

    # Create junit.xml file
    junit_cli.py --file "$logs/junit.xml" add \
      --suite $sd_section \
      --name "$sd_name" \
      --result $sd_result \
      --out "$tmp" \
      --start $sd_start \
      --end $sd_end
    rm -f "$sd_result_log" "$tmp"

    # Deactivate tools virtualenv
    deactivate

    set +x
    ) &>"$debug_log"
}

function junit_upload() {
    if [[ "$GOLDEN" != 'true' ]]; then
        echo "Build has not set GOLDEN variable, so results won't be uploaded to ReportPortal"
        return 0
    fi

    # Upload junit.xml into ReportPortal for test result investigation

    # Make the file available for Jenkins on the same path every time
    cp $logs/junit.xml latest-junit.xml

    [[ -n $PARAM_reportportal_host ]] || return 0

    # Activate tools virtualenv
    source venv/bin/activate

    # Determine ReportPortal launch name
    launch_name="${PARAM_reportportal_launch_name:-default-launch-name}"
    if echo "$launch_name" | grep -q '%sat_ver%'; then
        sat_ver="$( echo "$satellite_rpm" | sed 's/^satellite-//' | sed 's/^\([0-9]\+\.[0-9]\+\).*/\1/' )"
        [[ -n $sat_ver ]] || sat_ver="$( echo "$katello_rpm" | sed 's/^katello-//' | sed 's/^\([0-9]\+\.[0-9]\+\).*/\1/' )"
        launch_name="$( echo "$launch_name" | sed "s/%sat_ver%/$sat_ver/g" )"
    fi
    launch_name="$( echo "$launch_name" | sed 's/[^a-zA-Z0-9._-]/_/g' )"

    # Show content and upload to ReportPortal
    junit_cli.py --file "$logs/junit.xml" print
    junit_cli.py --file "$logs/junit.xml" upload \
      --host $PARAM_reportportal_host \
      --project $PARAM_reportportal_project \
      --token $PARAM_reportportal_token \
      --launch $launch_name \
      --noverify \
      --properties jenkins_build_url=$BUILD_URL run_id=$marker

    # Deactivate tools virtualenv
    deactivate
}

function log() {
    echo "[$( date -u -Iseconds )] $*"
}

function section() {
    name="${1:-default}"
    label="$( echo "$name" | sed 's/[^a-zA-Z0-9_-]/_/g' | sed 's/_\+/_/g' )"

    log "===== $name ====="
    export SECTION=$label
}

function _format_opts() {
    out=''
    while [[ -n $1 ]]; do
        if echo "$1" | grep -q ' '; then
            out_add="\"$1\""
        else
            out_add=$1
        fi
        if [[ -z "$out" ]]; then
            out="$out_add"
        else
            out+=" $out_add"
        fi
        shift
    done
    echo "$out"
}

function c() {
    if $run_lib_dryrun; then
        log 'FAKE command RUN'

        return 0
    fi

    local out="$logs/$1"; shift
    local start="$( date -u +%s )"

    mkdir -p "$logs"
    log "Start '$*' with log in $out"
    eval "$@" &>$out && local rc=$? || local rc=$?

    local end="$( date -u +%s )"
    log "Finish after $(( $end - $start )) seconds with log in $out and exit code $rc"

    measurement_add \
      "$@" \
      "$out" \
      "$rc" \
      "$start" \
      "$end" \
      "$katello_rpm" \
      "$satellite_rpm" \
      "$marker"

    return $rc
}

function a() {
    if $run_lib_dryrun; then
        log 'FAKE ansible RUN'

        return 0
    fi

    local out=$logs/$1; shift
    local start="$( date -u +%s )"

    mkdir -p "$logs"
    log "Start 'ansible $opts_adhoc $*' with log in $out"
    ansible $opts_adhoc "$@" &>$out && local rc=$? || local rc=$?

    local end="$( date -u +%s )"
    log "Finish after $(( $end - $start )) seconds with log in $out and exit code $rc"

    measurement_add \
      "ansible $opts_adhoc $( _format_opts "$@" )" \
      "$out" \
      "$rc" \
      "$start" \
      "$end" \
      "$katello_rpm" \
      "$satellite_rpm" \
      "$marker"

    return $rc
}

function a_out() {
    # Just run the ansible command. No output processing, action logging or measurements
    if $run_lib_dryrun; then
        echo 'FAKE ansible RUN'
    else
        ansible $opts_adhoc "$@"
    fi
}

function ap() {
    if $run_lib_dryrun; then
        log 'FAKE ansible-playbook RUN'

        return 0
    fi

    local out=$logs/$1; shift
    local start="$( date -u +%s )"

    mkdir -p "$logs"
    log "Start 'ANSIBLE_CALLBACKS_ENABLED='ansible.posix.profile_tasks' ansible-playbook $opts_adhoc $*' with log in $out"
    ANSIBLE_CALLBACKS_ENABLED='ansible.posix.profile_tasks' ansible-playbook $opts_adhoc "$@" &>$out && local rc=$? || local rc=$?

    local end="$( date -u +%s )"
    log "Finish after $(( end - start )) seconds with log in $out and exit code $rc"

    measurement_add \
      "ANSIBLE_CALLBACKS_ENABLED='ansible.posix.profile_tasks' ansible-playbook $opts_adhoc $( _format_opts "$@" )" \
      "$out" \
      "$rc" \
      "$start" \
      "$end" \
      "$katello_rpm" \
      "$satellite_rpm" \
      "$marker"

    return $rc
}

function apj() {
    if $run_lib_dryrun; then
        log 'FAKE ansible-playbook RUN'

        return 0
    fi

    local test=$1; shift
    local play_out_json="$logs/$test.json"

    mkdir -p "$logs"
    log "Start 'ANSIBLE_STDOUT_CALLBACK='ansible.posix.json' ansible-playbook $opts_adhoc $*' with JSON log in $play_out_json"
    ANSIBLE_STDOUT_CALLBACK='ansible.posix.json' ansible-playbook $opts_adhoc "$@" >$play_out_json && local rc=$? || local rc=$?

    # 'ansible.posix.json' returns datetimes by default ending in 'Z' and without timezone information, so we need to transform it for OPL consumption
    local play_start_z="$( jq '.plays[0].play.duration.start' $play_out_json )"
    local play_end_z="$( jq '.plays[0].play.duration.end' $play_out_json )"
    local play_start="$( python3 -c "from datetime import datetime; print(datetime.strptime($play_start_z, '%Y-%m-%dT%H:%M:%S.%fZ').astimezone().isoformat())" )"
    local play_end="$( python3 -c "from datetime import datetime; print(datetime.strptime($play_end_z, '%Y-%m-%dT%H:%M:%S.%fZ').astimezone().isoformat())" )"
    local play_duration="$( python3 -c "from datetime import datetime; print('{:.6f}'.format((datetime.strptime($play_end_z, '%Y-%m-%dT%H:%M:%S.%fZ') - datetime.strptime($play_start_z, '%Y-%m-%dT%H:%M:%S.%fZ')).total_seconds()))" )"
    log "Finish after $play_duration seconds with JSON log in $play_out_json and exit code $rc"

    measurement_add \
      "ANSIBLE_STDOUT_CALLBACK='ansible.posix.json' ansible-playbook $opts_adhoc $( _format_opts "$@" )" \
      "$play_out_json" \
      "$rc" \
      "$play_start" \
      "$play_end" \
      "$play_duration" \
      "$katello_rpm" \
      "$satellite_rpm" \
      "$marker"

    return $rc
}

function as() {
    local log_relative=$1; shift

    a "$log_relative" \
      -m ansible.builtin.shell \
      -a "$@" \
      satellite6
}

function s() {
    if $run_lib_dryrun; then
        log 'FAKE SLEEP'
    else
        log "Sleep for $1 seconds"
        sleep $1
    fi
}

function h() {
    local log_relative=$1; shift

    a "$log_relative" \
      -m ansible.builtin.shell \
      -a "hammer $hammer_opts $@" \
      satellite6
}

function h_drop() {
    # Run hammer command as usual, but drop its stdout
    local log_relative=$1; shift

    a "$log_relative" \
      -m ansible.builtin.shell \
      -a "hammer $hammer_opts $@ >/dev/null" \
      satellite6
}

function h_out() {
    # Just run the hammer command via ansible. No output processing, action logging or measurements
    a_out \
      -m ansible.builtin.shell \
      -a "hammer $hammer_opts $@" \
      satellite6
}

function e() {
    # Examine log for specific measure using reg-average.py
    local grepper=$1
    local log=$2
    local log_report="$( echo "$log" | sed "s/\.log$/-$grepper.log/" )"
    local hardened_grepper="$( echo "$grepper" | sed -e 's#\(\[\)#\\\1#' -e 's#\(\]\)#\\\1#' -e 's#\((\)#\\\1#' -e 's#\()\)#\\\1#' )"
    experiment/reg-average.py "$hardened_grepper" "$log" | sed -e 's#\\\(\[\)#\1#' -e 's#\\\(\]\)#\1#' -e 's#\\\((\)#\1#' -e 's#\\\()\)#\1#' &>"$log_report"
    local rc=$?
    local started_ts="$( grep '^min in' "$log_report" | tail -n 1 | cut -d ' ' -f 4 )"
    local ended_ts="$( grep '^max in' "$log_report" | tail -n 1 | cut -d ' ' -f 4 )"
    local duration="$( grep "^$hardened_grepper" "$log_report" | tail -n 1 | awk '{print $(NF-4)}' )"
    local passed="$( grep "^$hardened_grepper" "$log_report" | tail -n 1 | awk '{print $(NF-2)}' )"
    local avg_duration="$( grep "^$hardened_grepper" "$log_report" | tail -n 1 | awk '{print $NF}' )"
    log "Examined $log for $grepper: $duration / $passed = $avg_duration (ranging from $started_ts to $ended_ts) and has taken $avg_duration seconds"

    measurement_add \
      "experiment/reg-average.py '$grepper' '$log'" \
      "$log_report" \
      "$rc" \
      "$started_ts" \
      "$ended_ts" \
      "$katello_rpm" \
      "$satellite_rpm" \
      "$marker" \
      "results.items.duration=$duration results.items.passed=$passed results.items.avg_duration=$avg_duration results.items.report_rc=$rc"
}

function ej() {
    if $run_lib_dryrun; then
        log 'FAKE ansible-playbook RUN'

        return 0
    fi

    local task_name=$1; shift
    local test=$1; shift
    local play_out_json="$logs/$test.json"
    local play_out_json_prefix="$( echo $play_out_json | cut -d'.' -f1 )"
    local tasks_out_json="$play_out_json_prefix-$task_name.json"

    jq --arg TASK_NAME "$task_name" \
      '.plays[0].tasks[] | select(.task.name==$TASK_NAME and .hosts.localhost.skipped != null) | .task' \
      $play_out_json >$tasks_out_json

    task_ids="$( jq -r '.id' $tasks_out_json )"

    local num_tasks=0
    local aggregated_task_duration=0
    for task_id in $task_ids; do
        # 'ansible.posix.json' returns datetimes by default ending in 'Z' and without timezone information, so we need to transform it for OPL consumption
        local task_start_z="$( jq --arg TASK_ID "$task_id" \
          'select(.id==$TASK_ID) | .duration.start' \
          $tasks_out_json )"
        local task_end_z="$( jq --arg TASK_ID "$task_id" \
          'select(.id==$TASK_ID) | .duration.end' \
          $tasks_out_json )"
        local task_start="$( python3 -c "from datetime import datetime; print(datetime.strptime($task_start_z, '%Y-%m-%dT%H:%M:%S.%fZ').astimezone().isoformat())" )"
        local task_end="$( python3 -c "from datetime import datetime; print(datetime.strptime($task_end_z, '%Y-%m-%dT%H:%M:%S.%fZ').astimezone().isoformat())" )"
        local task_duration="$( python3 -c "from datetime import datetime; print((datetime.strptime($task_end_z, '%Y-%m-%dT%H:%M:%S.%fZ') - datetime.strptime($task_start_z, '%Y-%m-%dT%H:%M:%S.%fZ')).total_seconds())" )"
        if (( num_tasks == 0 )); then
            local first_task_start=$task_start
        fi
        local last_task_end=$task_end
        local aggregated_task_duration="$( python3 -c "print('{:.6f}'.format($aggregated_task_duration + $task_duration))" )"
        (( num_tasks++ ))
    done
    local average_task_duration="$( python3 -c "print('{:.6f}'.format($aggregated_task_duration / $num_tasks))" )"
    local rc=0
    log "Examined $tasks_out_json for $task_name: $aggregated_task_duration / $num_tasks = $average_task_duration (ranging from $first_task_start to $last_task_end) and has taken $average_task_duration seconds"

    measurement_add \
      "experiment/reg-average.py '$task_name' '$play_out_json'" \
      "$tasks_out_json" \
      "$rc" \
      "$first_task_start" \
      "$last_task_end" \
      "$aggregated_task_duration" \
      "$katello_rpm" \
      "$satellite_rpm" \
      "$marker" \
      "results.items.duration=$aggregated_task_duration results.items.passed=$num_tasks results.items.avg_duration=$average_task_duration results.items.report_rc=$rc"

    return $rc
}

function task_examine() {
    # Show task duration without outliners
    local log=$1
    local task_id=$2
    [[ -n $task_id ]] || return 1
    local command="${3:-N/A}"
    local timeout="${4:-10}"
    local satellite_host="$( ansible $opts_adhoc \
      --list-hosts \
      satellite6 2>/dev/null |
      tail -n 1 | sed -e 's/^\s\+//' -e 's/\s\+$//' -e 's/^ *//' )"
    [[ -n $satellite_host ]] || return 2
    local log_report="$( echo "$log" | sed 's/\.log$/-duration.log/' )"

    scripts/get-task-fuzzy-duration.py \
      --hostname $satellite_host \
      --task-id $task_id \
      --timeout $timeout \
      --percentage 0 \
      --output status-data \
      &>${log_report}
    local rc=$?
    if (( rc == 0 )); then
        started="$( awk -F'"' '/^results.tasks.start=/ {printf ("%s", $2)}' $log_report )"
        started_ts="$( date -d $started +%s )"
        ended="$( awk -F'"' '/^results.tasks.end=/ {printf ("%s", $2)}' $log_report )"
        ended_ts="$( date -d $ended +%s )"
        duration="$( awk -F'"' '/^results.tasks.duration=/ {printf ("%.0f", $2)}' $log_report )"
        head_tail_perc="$( awk -F'"' '/^results.tasks.percentage_removed=/ {printf ("%.2f", $2)}' $log_report )"
        log "Examined task $task_id and it has $head_tail_perc % of head/tail (ranging from $started_ts to $ended_ts) and has taken $duration seconds"

        measurement_add \
          "$command" \
          "$log_report" \
          "$rc" \
          "$started_ts" \
          "$ended_ts" \
          "$katello_version" \
          "$satellite_version" \
          "$marker" \
          "$( grep '^results.tasks.[a-zA-Z0-9_]*="[^"]*"$' $log_report )"
        return 0
    else
        log "There were errors examining the task $task_id. Please check $log and $log_report log files"
        return 1
    fi
}

function t() {
    # Parse task ID from the log and examine the task
    local log=$1
    local task_id="$( extract_task "$log" )"
    [[ -n $task_id ]] || return 1

    task_examine "$log" "$task_id" "Investigating task $task_id"
}

function j() {
    # Parse job invocation ID from the log, get parent task ID and examine it
    local log=$1
    local job_invocation_id="$( extract_job_invocation "$log" )"
    [[ -n $job_invocation_id ]] || return 1
    local satellite_host="$( ansible $opts_adhoc \
      --list-hosts \
      satellite6 2>/dev/null |
      tail -n 1 | sed -e 's/^\s\+//' -e 's/\s\+$//' -e 's/^ *//' )"
    [[ -n $satellite_host ]] || return 2
    local satellite_creds="$( ansible $opts_adhoc \
      -m ansible.builtin.debug \
      -a "msg={{ sat_user }}:{{ sat_pass }}" \
      satellite6 2>/dev/null |
      grep '"msg":' | cut -d '"' -f 4)"
    [[ -n $satellite_creds ]] || return 2
    local task_id="$( curl --silent --insecure \
      -u "$satellite_creds" \
      -X GET \
      -H 'Accept: application/json' \
      -H 'Content-Type: application/json' \
      --max-time 30 \
      https://$satellite_host/api/job_invocations?search=id=$job_invocation_id |
      python3 -c 'import json, sys; print(json.load(sys.stdin)["results"][0]["dynflow_task"]["id"])' )"

    task_examine "$log" "$task_id" "Investigating job invocation $job_invocation_id (task $task_id)"
}

function jsr() {
    # Parse job invocation ID from the log and show its execution success ratio
    local log=$1
    local timeout="${2:-10}"
    local job_invocation_id="$( extract_job_invocation "$log" )"
    [[ -n $job_invocation_id ]] || return 1
    local satellite_host="$( ansible $opts_adhoc \
      --list-hosts \
      satellite6 2>/dev/null |
      tail -n 1 | sed -e 's/^\s\+//' -e 's/\s\+$//' -e 's/^ *//' )"
    [[ -n $satellite_host ]] || return 2
    local satellite_creds="$( ansible $opts_adhoc \
      -m ansible.builtin.debug \
      -a "msg={{ sat_user }}:{{ sat_pass }}" \
      satellite6 2>/dev/null |
      grep '"msg":' | cut -d '"' -f 4 )"
    [[ -n $satellite_creds ]] || return 2
    local satellite_user="$( echo "$satellite_creds" | cut -d':' -f1 )"
    local satellite_pass="$( echo "$satellite_creds" | cut -d':' -f2 )"

    scripts/wait_for_job.py \
      --hostname $satellite_host \
      --username $satellite_user \
      --password $satellite_pass \
      --job-id $job_invocation_id \
      --timeout $timeout

    return 0
}

function extract_task() {
    # Take log with hammer run log and extract task ID from it. Do not return
    # anything if more task IDs are found or in case of any other error.
    log=$1
    candidates="$( grep '^Task [0-9a-zA-Z-]\+ running' $log | cut -d ' ' -f 2 | uniq )"
    # Only print if we have exactly one task ID
    if (( "$( echo "$candidates" | wc -l | sed 's/^ *//' )" == 1 )); then
        echo "$candidates"
        return 0
    fi
    return 1
}

function extract_job_invocation() {
    # Take log with hammer job-invocation create --async output and extract
    # job invocation ID from it. Do not return anything if more IDs are found
    # or in case of any other error.
    log=$1
    candidates="$( grep '^Job invocation [0-9]\+ created' $log | cut -d ' ' -f 3 | uniq )"
    # Only print if we have exactly one job invocation ID
    if (( "$( echo "$candidates" | wc -l | sed 's/^ *//' )" == 1 )); then
        echo "$candidates"
        return 0
    fi
    return 1
}

function table_row() {
    # Format row for results table with average duration
    local identifier="/$( echo "$1" | sed 's/\./\./g' ),"
    local description=$2
    local grepper=$3
    export IFS=$'\n'
    local count=0
    local sum=0
    local note=''
    for row in $( grep "$identifier" $logs/measurement.log ); do
        local rc="$( echo "$row" | measurement_row_field 3 )"
        if (( rc != 0 )); then
            echo "ERROR: Row '$row' have non-zero return code. Not considering it when counting duration :-(" >&2
            continue
        fi
        if [ -n "$grepper" ]; then
            local log="$( echo "$row" | measurement_row_field 2 )"
            local out="$( experiment/reg-average.py "$grepper" "$log" 2>/dev/null | grep "^$grepper in " | tail -n 1 )"
            local passed="$( echo "$out" | cut -d ' ' -f 6 )"
            [[ -n $note ]] || note='Number of passed:'
            local note="$note $passed"
            local diff="$( echo "$out" | cut -d ' ' -f 8 )"
            if [ -n "$diff" ]; then
                (( sum += diff ))
                (( count++ ))
            fi
        else
            local start="$( echo "$row" | measurement_row_field 4 )"
            local end="$( echo "$row"| measurement_row_field 5 )"
            (( sum += end - start ))
            (( count++ ))
        fi
    done
    if (( count == 0 )); then
        local avg='N/A'
    else
        local avg="$( echo "scale=2; $sum / $count" | bc )"
    fi
    echo -e "$description\t$avg\t$note"
}


# Create dir for logs
mkdir -p "$logs"
log "Logging into '$logs/' directory"
