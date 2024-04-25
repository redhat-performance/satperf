#!/bin/bash

source experiment/run-library.sh

branch="${PARAM_branch:-satcpt}"
inventory="${PARAM_inventory:-conf/contperf/inventory.${branch}.ini}"
sat_version="${PARAM_sat_version:-stream}"
manifest="${PARAM_manifest:-conf/contperf/manifest_SCA.zip}"

cdn_url_full="${PARAM_cdn_url_full:-https://cdn.redhat.com/}"
cdn_url_mirror="${PARAM_cdn_url_mirror:-https://cdn.redhat.com/}"

rels="${PARAM_rels:-rhel6 rhel7 rhel8 rhel9}"

lces="${PARAM_lces:-Test QA Pre Prod}"

basearch='x86_64'

sat_client_product='Satellite Client'

repo_sat_client_6="${PARAM_repo_sat_client_6:-http://mirror.example.com/Satellite_Client_6_${basearch}/}"
repo_sat_client_7="${PARAM_repo_sat_client_7:-http://mirror.example.com/Satellite_Client_7_${basearch}/}"
repo_sat_client_8="${PARAM_repo_sat_client_8:-http://mirror.example.com/Satellite_Client_8_${basearch}/}"
repo_sat_client_9="${PARAM_repo_sat_client_9:-http://mirror.example.com/Satellite_Client_9_${basearch}/}"

initial_expected_concurrent_registrations="${PARAM_initial_expected_concurrent_registrations:-64}"

test_sync_repositories_count="${PARAM_test_sync_repositories_count:-8}"
test_sync_repositories_url_template="${PARAM_test_sync_repositories_url_template:-http://repos.example.com/repo*}"
test_sync_repositories_max_sync_secs="${PARAM_test_sync_repositories_max_sync_secs:-600}"
test_sync_iso_count="${PARAM_test_sync_iso_count:-8}"
test_sync_iso_url_template="${PARAM_test_sync_iso_url_template:-http://storage.example.com/iso-repos*}"
test_sync_iso_max_sync_secs="${PARAM_test_sync_iso_max_sync_secs:-600}"
test_sync_docker_count="${PARAM_test_sync_docker_count:-8}"
test_sync_docker_url_template="${PARAM_test_sync_docker_url_template:-https://registry-1.docker.io}"
test_sync_docker_max_sync_secs="${PARAM_test_sync_docker_max_sync_secs:-600}"

ui_pages_concurrency="${PARAM_ui_pages_concurrency:-10}"
ui_pages_duration="${PARAM_ui_pages_duration:-300}"

dl="Default Location"

opts="--forks 100 -i $inventory"
opts_adhoc="$opts"


section "Checking environment"
generic_environment_check


section "Prepare for Red Hat content"
skip_measurement='true' ap 01-manifest-excercise.log \
  -e "organization='{{ sat_org }}'" \
  -e "manifest=../../$manifest" \
  playbooks/tests/manifest-excercise.yaml
e ManifestUpload $logs/01-manifest-excercise.log
e ManifestRefresh $logs/01-manifest-excercise.log
e ManifestDelete $logs/01-manifest-excercise.log
skip_measurement='true' h 02-manifest-upload.log "subscription upload --file '/root/manifest-auto.zip' --organization '{{ sat_org }}'"


section "Create LCE(s)"
prior='Library'
for lce in $lces; do
    h 09-lce-create-${lce}.log "lifecycle-environment create --organization '{{ sat_org }}' --prior '$prior' --name '$lce'"

    prior="${lce}"
done


section "Sync from mirror"
if [[ "$cdn_url_mirror" != 'https://cdn.redhat.com/' ]]; then
    skip_measurement='true' h 00-set-local-cdn-mirror.log "organization update --name '{{ sat_org }}' --redhat-repository-url '$cdn_url_mirror'"
fi
skip_measurement='true' h 00-manifest-refresh.log "subscription refresh-manifest --organization '{{ sat_org }}'"

sca_status="$(h_out "--no-headers --csv simple-content-access status --organization '{{ sat_org }}'" | grep -v "^$satellite_host \| ")"

for rel in $rels; do
    case $rel in
        rhel6)
            os_product='Red Hat Enterprise Linux Server'
            os_releasever='6Server'
            os_reposet_name='Red Hat Enterprise Linux 6 Server (RPMs)'
            os_repo_name="Red Hat Enterprise Linux 6 Server RPMs $basearch $os_releasever"
            ;;
        rhel7)
            os_product='Red Hat Enterprise Linux Server'
            os_releasever='7Server'
            os_reposet_name='Red Hat Enterprise Linux 7 Server (RPMs)'
            os_repo_name="Red Hat Enterprise Linux 7 Server RPMs $basearch $os_releasever"
            os_extras_reposet_name='Red Hat Enterprise Linux 7 Server - Extras (RPMs)'
            os_extras_repo_name="Red Hat Enterprise Linux 7 Server - Extras RPMs $basearch"
            ;;
        rhel8)
            os_product="Red Hat Enterprise Linux for $basearch"
            os_releasever='8'
            os_reposet_name="Red Hat Enterprise Linux 8 for $basearch - BaseOS (RPMs)"
            os_repo_name="Red Hat Enterprise Linux 8 for $basearch - BaseOS RPMs $os_releasever"
            os_appstream_reposet_name="Red Hat Enterprise Linux 8 for $basearch - AppStream (RPMs)"
            os_appstream_repo_name="Red Hat Enterprise Linux 8 for $basearch - AppStream RPMs $os_releasever"
            ;;
        rhel9)
            os_product="Red Hat Enterprise Linux for $basearch"
            os_releasever='9'
            os_reposet_name="Red Hat Enterprise Linux 9 for $basearch - BaseOS (RPMs)"
            os_repo_name="Red Hat Enterprise Linux 9 for $basearch - BaseOS RPMs $os_releasever"
            os_appstream_reposet_name="Red Hat Enterprise Linux 9 for $basearch - AppStream (RPMs)"
            os_appstream_repo_name="Red Hat Enterprise Linux 9 for $basearch - AppStream RPMs $os_releasever"
            ;;
    esac

    case $rel in
        rhel6)
            skip_measurement='true' h 10-reposet-enable-${rel}.log "repository-set enable --organization '{{ sat_org }}' --product '$os_product' --name '$os_reposet_name' --releasever '$os_releasever' --basearch '$basearch'"
            h 12-repo-sync-${rel}.log "repository synchronize --organization '{{ sat_org }}' --product '$os_product' --name '$os_repo_name'"
            ;;
        rhel7)
            skip_measurement='true' h 10-reposet-enable-${rel}.log "repository-set enable --organization '{{ sat_org }}' --product '$os_product' --name '$os_reposet_name' --releasever '$os_releasever' --basearch '$basearch'"
            h 12-repo-sync-${rel}.log "repository synchronize --organization '{{ sat_org }}' --product '$os_product' --name '$os_repo_name'"

            skip_measurement='true' h 10-reposet-enable-${rel}extras.log "repository-set enable --organization '{{ sat_org }}' --product '$os_product' --name '$os_extras_reposet_name' --releasever '$os_releasever' --basearch '$basearch'"
            h 12-repo-sync-${rel}extras.log "repository synchronize --organization '{{ sat_org }}' --product '$os_product' --name '$os_extras_repo_name'"
            ;;
        rhel8|rhel9)
            skip_measurement='true' h 10-reposet-enable-${rel}baseos.log "repository-set enable --organization '{{ sat_org }}' --product '$os_product' --name '$os_reposet_name' --releasever '$os_releasever' --basearch '$basearch'"
            h 12-repo-sync-${rel}baseos.log "repository synchronize --organization '{{ sat_org }}' --product '$os_product' --name '$os_repo_name'"

            skip_measurement='true' h 10-reposet-enable-${rel}appstream.log "repository-set enable --organization '{{ sat_org }}' --product '$os_product' --name '$os_appstream_reposet_name' --releasever '$os_releasever' --basearch '$basearch'"
            h 12-repo-sync-${rel}appstream.log "repository synchronize --organization '{{ sat_org }}' --product '$os_product' --name '$os_appstream_repo_name'"
            ;;
    esac
done


section "Create, publish and promote CVs / CCVs to LCE(s)s"
for rel in $rels; do
    cv_os="CV_$rel"
    cv_sat_client="CV_${rel}-sat-client"
    ccv="CCV_$rel"

    case $rel in
        rhel6)
            os_product='Red Hat Enterprise Linux Server'
            os_releasever='6Server'
            os_repo_name="Red Hat Enterprise Linux 6 Server RPMs $basearch $os_releasever"
            os_rids="$( get_repo_id '{{ sat_org }}' "$os_product" "$os_repo_name" )"
            ;;
        rhel7)
            os_product='Red Hat Enterprise Linux Server'
            os_releasever='7Server'
            os_repo_name="Red Hat Enterprise Linux 7 Server RPMs $basearch $os_releasever"
            os_extras_repo_name="Red Hat Enterprise Linux 7 Server - Extras RPMs $basearch"
            os_rids="$( get_repo_id '{{ sat_org }}' "$os_product" "$os_repo_name" )"
            os_rids="$os_rids,$( get_repo_id '{{ sat_org }}' "$os_product" "$os_extras_repo_name" )"
            ;;
        rhel8)
            os_product="Red Hat Enterprise Linux for $basearch"
            os_releasever='8'
            os_repo_name="Red Hat Enterprise Linux 8 for $basearch - BaseOS RPMs $os_releasever"
            os_appstream_repo_name="Red Hat Enterprise Linux 8 for $basearch - AppStream RPMs $os_releasever"
            os_rids="$( get_repo_id '{{ sat_org }}' "$os_product" "$os_repo_name" )"
            os_rids="$os_rids,$( get_repo_id '{{ sat_org }}' "$os_product" "$os_appstream_repo_name" )"
            ;;
        rhel9)
            os_product="Red Hat Enterprise Linux for $basearch"
            os_releasever='9'
            os_repo_name="Red Hat Enterprise Linux 9 for $basearch - BaseOS RPMs $os_releasever"
            os_appstream_repo_name="Red Hat Enterprise Linux 9 for $basearch - AppStream RPMs $os_releasever"
            os_rids="$( get_repo_id '{{ sat_org }}' "$os_product" "$os_repo_name" )"
            os_rids="$os_rids,$( get_repo_id '{{ sat_org }}' "$os_product" "$os_appstream_repo_name" )"
            ;;
    esac

    # OS CV
    h 13b-cv-create-${rel}-os.log "content-view create --organization '{{ sat_org }}' --name '$cv_os' --repository-ids '$os_rids'"
    h 13b-cv-publish-${rel}-os.log "content-view publish --organization '{{ sat_org }}' --name '$cv_os'"

    # CCV
    h 13c-ccv-create-${rel}.log "content-view create --organization '{{ sat_org }}' --composite --auto-publish yes --name '$ccv'"

    h 13c-ccv-component-add-${rel}-os.log "content-view component add --organization '{{ sat_org }}' --composite-content-view '$ccv' --component-content-view '$cv_os' --latest"
    h 13c-ccv-publish-${rel}-os.log "content-view publish --organization '{{ sat_org }}' --name '$ccv'"

    # Promotion to LCE(s)
    tmp="$( mktemp )"
    h_out "--no-headers --csv content-view version list --organization '{{ sat_org }}' --content-view '$ccv'" | grep '^[0-9]\+,' >$tmp
    version="$( head -n1 $tmp | cut -d ',' -f 3 | tr '\n' ',' | sed 's/,$//' )"
    rm -f $tmp

    prior='Library'
    for lce in $lces; do
        h 13d-ccv-promote-${rel}-${lce}.log "content-view version promote --organization '{{ sat_org }}' --content-view '$ccv' --version '$version' --from-lifecycle-environment '$prior' --to-lifecycle-environment '$lce'"

        prior="${lce}"
    done
done


section "Push content to capsules"
ap 14-capsync-populate.log \
  -e "organization='{{ sat_org }}'" \
  -e "lces='$lces'" \
  playbooks/satellite/capsules-populate.yaml


section "Publish and promote big CV"
cv='BenchContentView'
rids="$( get_repo_id '{{ sat_org }}' 'Red Hat Enterprise Linux Server' "Red Hat Enterprise Linux 6 Server RPMs $basearch 6Server" )"
rids="$rids,$( get_repo_id '{{ sat_org }}' 'Red Hat Enterprise Linux Server' "Red Hat Enterprise Linux 7 Server RPMs $basearch 7Server" )"
rids="$rids,$( get_repo_id '{{ sat_org }}' 'Red Hat Enterprise Linux Server' "Red Hat Enterprise Linux 7 Server - Extras RPMs $basearch" )"

skip_measurement='true' h 20-cv-create-big.log "content-view create --organization '{{ sat_org }}' --repository-ids '$rids' --name '$cv'"
h 21-cv-publish-big.log "content-view publish --organization '{{ sat_org }}' --name '$cv'"

prior='Library'
counter=1
for lce in BenchLifeEnvAAA BenchLifeEnvBBB BenchLifeEnvCCC; do
    skip_measurement='true' h 22-le-create-${prior}-${lce}.log "lifecycle-environment create --organization '{{ sat_org }}' --prior '$prior' --name '$lce'"
    h 23-cv-promote-big-${prior}-${lce}.log "content-view version promote --organization '{{ sat_org }}' --content-view '$cv' --to-lifecycle-environment '$prior' --to-lifecycle-environment '$lce'"

    prior="${lce}"
    (( counter++ ))
done


section "Publish and promote filtered CV"
export skip_measurement='true'
cv='BenchFilteredContentView'
rids="$( get_repo_id '{{ sat_org }}' 'Red Hat Enterprise Linux Server' "Red Hat Enterprise Linux 6 Server RPMs $basearch 6Server" )"

h 30-cv-create-filtered.log "content-view create --organization '{{ sat_org }}' --repository-ids '$rids' --name '$cv'"

h 31-filter-create-1.log "content-view filter create --organization '{{ sat_org }}' --type erratum --inclusion true --content-view '$cv' --name BenchFilterAAA"
h 31-filter-create-2.log "content-view filter create --organization '{{ sat_org }}' --type erratum --inclusion true --content-view '$cv' --name BenchFilterBBB"

h 32-rule-create-1.log "content-view filter rule create --content-view '$cv' --content-view-filter BenchFilterAAA --date-type 'issued' --start-date 2016-01-01 --end-date 2017-10-01 --organization '{{ sat_org }}' --types enhancement,bugfix,security"
h 32-rule-create-2.log "content-view filter rule create --content-view '$cv' --content-view-filter BenchFilterBBB --date-type 'updated' --start-date 2016-01-01 --end-date 2018-01-01 --organization '{{ sat_org }}' --types security"
unset skip_measurement

h 33-cv-filtered-publish.log "content-view publish --organization '{{ sat_org }}' --name '$cv'"


export skip_measurement='true'
section "Sync from CDN do not measure"   # do not measure because of unpredictable network latency
h 00b-set-cdn-stage.log "organization update --name '{{ sat_org }}' --redhat-repository-url '$cdn_url_full'"
# 
# h 00b-manifest-refresh.log "subscription refresh-manifest --organization '{{ sat_org }}'"

for rel in $rels; do
    case $rel in
        rhel6)
            os_product='Red Hat Enterprise Linux Server'
            os_releasever='6Server'
            os_reposet_name='Red Hat Enterprise Linux 6 Server (RPMs)'
            os_repo_name="Red Hat Enterprise Linux 6 Server RPMs $basearch $os_releasever"
            ;;
        rhel7)
            os_product='Red Hat Enterprise Linux Server'
            os_releasever='7Server'
            os_reposet_name='Red Hat Enterprise Linux 7 Server (RPMs)'
            os_repo_name="Red Hat Enterprise Linux 7 Server RPMs $basearch $os_releasever"
            os_extras_reposet_name='Red Hat Enterprise Linux 7 Server - Extras (RPMs)'
            os_extras_repo_name="Red Hat Enterprise Linux 7 Server - Extras RPMs $basearch"
            ;;
        rhel8)
            os_product="Red Hat Enterprise Linux for $basearch"
            os_releasever='8'
            os_reposet_name="Red Hat Enterprise Linux 8 for $basearch - BaseOS (RPMs)"
            os_repo_name="Red Hat Enterprise Linux 8 for $basearch - BaseOS RPMs $os_releasever"
            os_appstream_reposet_name="Red Hat Enterprise Linux 8 for $basearch - AppStream (RPMs)"
            os_appstream_repo_name="Red Hat Enterprise Linux 8 for $basearch - AppStream RPMs $os_releasever"
            ;;
        rhel9)
            os_product="Red Hat Enterprise Linux for $basearch"
            os_releasever='9'
            os_reposet_name="Red Hat Enterprise Linux 9 for $basearch - BaseOS (RPMs)"
            os_repo_name="Red Hat Enterprise Linux 9 for $basearch - BaseOS RPMs $os_releasever"
            os_appstream_reposet_name="Red Hat Enterprise Linux 9 for $basearch - AppStream (RPMs)"
            os_appstream_repo_name="Red Hat Enterprise Linux 9 for $basearch - AppStream RPMs $os_releasever"
            ;;
    esac

    case $rel in
        rhel6)
            h 12b-repo-sync-${rel}.log "repository synchronize --organization '{{ sat_org }}' --product '$os_product' --name '$os_repo_name'" &
            ;;
        rhel7)
            h 12b-repo-sync-${rel}.log "repository synchronize --organization '{{ sat_org }}' --product '$os_product' --name '$os_repo_name'" &
            h 12b-repo-sync-${rel}extras.log "repository synchronize --organization '{{ sat_org }}' --product '$os_product' --name '$os_extras_repo_name'" &
            ;;
        rhel8|rhel9)
            h 12b-repo-sync-${rel}baseos.log "repository synchronize --organization '{{ sat_org }}' --product '$os_product' --name '$os_repo_name'" &
            h 12b-repo-sync-${rel}appstream.log "repository synchronize --organization '{{ sat_org }}' --product '$os_product' --name '$os_appstream_repo_name'" &
            ;;
    esac
done
wait
unset skip_measurement


export skip_measurement='true'
section "Get Satellite Client content"
# Satellite Client
h 30-sat-client-product-create.log "product create --organization '{{ sat_org }}' --name '$sat_client_product'"

for rel in $rels; do
    case $rel in
        rhel6)
            sat_client_repo_name='Satellite Client for RHEL 6'
            sat_client_repo_url="$repo_sat_client_6"
            ;;
        rhel7)
            sat_client_repo_name='Satellite Client for RHEL 7'
            sat_client_repo_url="$repo_sat_client_7"
            ;;
        rhel8)
            sat_client_repo_name='Satellite Client for RHEL 8'
            sat_client_repo_url="$repo_sat_client_8"
            ;;
        rhel9)
            sat_client_repo_name='Satellite Client for RHEL 9'
            sat_client_repo_url="$repo_sat_client_9"
            ;;
    esac

    h 30-repository-create-sat-client_${rel}.log "repository create --organization '{{ sat_org }}' --product '$sat_client_product' --name '$sat_client_repo_name' --content-type yum --url '$sat_client_repo_url'"
    h 30-repository-sync-sat-client_${rel}.log "repository synchronize --organization '{{ sat_org }}' --product '$sat_client_product' --name '$sat_client_repo_name'" &
done
wait


for rel in $rels; do
    cv_sat_client="CV_${rel}-sat-client"
    ccv="CCV_${rel}"

    case $rel in
        rhel6)
            sat_client_repo_name='Satellite Client for RHEL 6'
            sat_client_rids="$( get_repo_id '{{ sat_org }}' "$sat_client_product" "$sat_client_repo_name" )"
            ;;
        rhel7)
            sat_client_repo_name='Satellite Client for RHEL 7'
            sat_client_rids="$( get_repo_id '{{ sat_org }}' "$sat_client_product" "$sat_client_repo_name" )"
            ;;
        rhel8)
            sat_client_repo_name='Satellite Client for RHEL 8'
            sat_client_rids="$( get_repo_id '{{ sat_org }}' "$sat_client_product" "$sat_client_repo_name" )"
            ;;
        rhel9)
            sat_client_repo_name='Satellite Client for RHEL 9'
            sat_client_rids="$( get_repo_id '{{ sat_org }}' "$sat_client_product" "$sat_client_repo_name" )"
            ;;
    esac
    content_label="$( h_out "--no-headers --csv repository list --organization '{{ sat_org }}' --search 'name = \"$sat_client_repo_name\"' --fields 'Content label'" | tail -n1 )"

    # Satellite Client CV
    h 34-cv-create-${rel}-sat-client.log "content-view create --organization '{{ sat_org }}' --name '$cv_sat_client' --repository-ids '$sat_client_rids'"
    h 35-cv-publish-${rel}-sat-client.log "content-view publish --organization '{{ sat_org }}' --name '$cv_sat_client'"

    # CCV
    h 36-ccv-component-add-${rel}-sat-client.log "content-view component add --organization '{{ sat_org }}' --composite-content-view '$ccv' --component-content-view '$cv_sat_client' --latest"
    h 37-ccv-publish-${rel}-sat-client.log "content-view publish --organization '{{ sat_org }}' --name '$ccv'"

    tmp="$( mktemp )"
    h_out "--no-headers --csv content-view version list --organization '{{ sat_org }}' --content-view '$ccv'" | grep '^[0-9]\+,' >$tmp
    version="$( head -n1 $tmp | cut -d ',' -f 3 | tr '\n' ',' | sed 's/,$//' )"
    rm -f $tmp

    prior='Library'
    for lce in $lces; do
        ak="AK_${rel}_${lce}"
        id="$( h_out "--no-headers --csv activation-key list --organization '{{ sat_org }}' --search 'name = \"$ak\"' --fields id"  | tail -n1 )"

        # CCV promotion to LCE
        h 38-ccv-promote-${rel}-${lce}.log "content-view version promote --organization '{{ sat_org }}' --content-view '$ccv' --version '$version' --from-lifecycle-environment '$prior' --to-lifecycle-environment '$lce'"

        # AK creation
        h 39-ak-create-${rel}-${lce}.log "activation-key create --content-view '$ccv' --lifecycle-environment '$lce' --name '$ak' --organization '{{ sat_org }}'"

        # Enable 'Satellite Client' repo in AK
        h 40-ak-create-${rel}-${lce}.log "activation-key content-override --organization '{{ sat_org }}' --id $id --content-label $content_label --override-name 'enabled' --value 1"

        prior="${lce}"
    done
done
unset skip_measurement


export skip_measurement='true'
section "Push content to capsules"   # We just added up2date content from CDN and $sat_client_product, so no reason to measure this now
ap 14b-capsync-populate.log \
  -e "organization='{{ sat_org }}'" \
  -e "lces='$lces'" \
  playbooks/satellite/capsules-populate.yaml
unset skip_measurement


export skip_measurement='true'
section "Prepare for registrations"
h_out "--no-headers --csv domain list --search 'name = {{ domain }}'" | grep --quiet '^[0-9]\+,' \
  || h 42-domain-create.log "domain create --name '{{ domain }}' --organizations '{{ sat_org }}'"

tmp="$( mktemp )"
h_out "--no-headers --csv location list --organization '{{ sat_org }}'" | grep '^[0-9]\+,' >$tmp
location_ids="$( cut -d ',' -f 1 $tmp | tr '\n' ',' | sed 's/,$//' )"
rm -f $tmp

h 42-domain-update.log "domain update --name '{{ domain }}' --organizations '{{ sat_org }}' --location-ids '$location_ids'"

ak='AK_rhel8_Test'

ap 44-generate-host-registration-command.log \
  -e "organization='{{ sat_org }}'" \
  -e "ak='$ak'" \
  -e "sat_version='$sat_version'" \
  playbooks/satellite/host-registration_generate-command.yaml

ap 45-recreate-client-scripts.log \
  playbooks/satellite/client-scripts.yaml
unset skip_measurement


section "Incremental registrations and remote execution"
number_container_hosts="$( ansible $opts_adhoc --list-hosts container_hosts 2>/dev/null | grep '^  hosts' | sed 's/^  hosts (\([0-9]\+\)):$/\1/' )"
number_containers_per_container_host="$( ansible $opts_adhoc -m ansible.builtin.debug -a "var=containers_count" container_hosts[0] | awk '/    "containers_count":/ {print $NF}' )"
if (( initial_expected_concurrent_registrations > number_container_hosts )); then
    initial_concurrent_registrations_per_container_host="$(( initial_expected_concurrent_registrations / number_container_hosts ))"
else
    initial_concurrent_registrations_per_container_host=1
fi
num_retry_forks="$(( initial_expected_concurrent_registrations / number_container_hosts ))"
job_template_ansible_default='Run Command - Ansible Default'
job_template_ssh_default='Run Command - Script Default'

skip_measurement='true' h 46-rex-set-via-ip.log "settings set --name remote_execution_connect_by_ip --value true"
skip_measurement='true' a 47-rex-cleanup-know_hosts.log \
  -m ansible.builtin.shell \
  -a "rm -rf /usr/share/foreman-proxy/.ssh/known_hosts*" \
  satellite6

for (( batch=1, remaining_containers_per_container_host=$number_containers_per_container_host, total_registered=0; remaining_containers_per_container_host > 0; batch++ )); do
    if (( remaining_containers_per_container_host > initial_concurrent_registrations_per_container_host * batch )); then
        concurrent_registrations_per_container_host="$(( initial_concurrent_registrations_per_container_host * batch ))"
    else
        concurrent_registrations_per_container_host="$(( remaining_containers_per_container_host ))"
    fi
    concurrent_registrations="$(( concurrent_registrations_per_container_host * number_container_hosts ))"

    log "Trying to register $concurrent_registrations content hosts concurrently in this batch"

    (( remaining_containers_per_container_host -= concurrent_registrations_per_container_host ))

    skip_measurement='true' ap 48-register-$concurrent_registrations.log \
      -e "size='$concurrent_registrations_per_container_host'" \
      -e "num_retry_forks='$num_retry_forks'" \
      -e "registration_logs='../../$logs/48-register-docker-host-client-logs'" \
      -e 're_register_failed_hosts=true' \
      -e "sat_version='$sat_version'" \
      playbooks/tests/registrations.yaml
      e Register $logs/48-register-$concurrent_registrations.log

    (( total_registered += concurrent_registrations ))

    skip_measurement='true' h 55-rex-date-${total_registered}.log "job-invocation create --async --description-format '${total_registered} hosts - Run %{command} (%{template_name})' --inputs command='date' --job-template '$job_template_ssh_default' --search-query 'name ~ container'"
    jsr $logs/55-rex-date-${total_registered}.log
    j $logs/55-rex-date-${total_registered}.log

    skip_measurement='true' h 56-rex-date-ansible-${total_registered}.log "job-invocation create --async --description-format '${total_registered} hosts - Run %{command} (%{template_name})' --inputs command='date' --job-template '$job_template_ansible_default' --search-query 'name ~ container'"
    jsr $logs/56-rex-date-ansible-${total_registered}.log
    j $logs/56-rex-date-ansible-${total_registered}.log
done
grep Register $logs/48-register-*.log >$logs/48-register-overall.log
e Register $logs/48-register-overall.log

skip_measurement='true' h 59-rex-katello_package_update-${total_registered}.log "job-invocation create --async --description-format '${total_registered} hosts - (%{template_name})' --feature katello_package_update --search-query 'name ~ container'"
jsr $logs/59-rex-katello_package_update-${total_registered}.log
j $logs/59-rex-katello_package_update-${total_registered}.log


section "Misc simple tests"
ap 61-hammer-list.log \
  -e "organization='{{ sat_org }}'" \
  playbooks/tests/hammer-list.yaml
e HammerHostList $logs/61-hammer-list.log

rm -f /tmp/status-data-webui-pages.json
skip_measurement='true' ap 62-webui-pages.log \
  -e "sat_version='$sat_version'" \
  -e "ui_pages_concurrency='$ui_pages_concurrency'" \
  -e "ui_pages_duration='$ui_pages_duration'" \
  playbooks/tests/webui-pages.yaml
STATUS_DATA_FILE=/tmp/status-data-webui-pages.json e WebUIPagesTest_c${ui_pages_concurrency}_d${ui_pages_duration} $logs/62-webui-pages.log
a 63-foreman_inventory_upload-report-generate.log satellite6 \
  -m ansible.builtin.shell \
  -a "export organization='{{ sat_org }}'; export target=/var/lib/foreman/red_hat_inventory/generated_reports/; /usr/sbin/foreman-rake rh_cloud_inventory:report:generate"


section "BackupTest"
skip_measurement='true' ap 70-backup.log playbooks/tests/sat-backup.yaml
e BackupOffline $logs/70-backup.log
e RestoreOffline $logs/70-backup.log
e BackupOnline $logs/70-backup.log
e RestoreOnline $logs/70-backup.log


section "Sync yum repo"
ap 80-test-sync-repositories.log \
  -e "organization='{{ sat_org }}'" \
  -e "test_sync_repositories_count='$test_sync_repositories_count'" \
  -e "test_sync_repositories_url_template='$test_sync_repositories_url_template'" \
  -e "test_sync_repositories_max_sync_secs='$test_sync_repositories_max_sync_secs'" \
  playbooks/tests/sync-repositories.yaml

e SyncRepositories $logs/80-test-sync-repositories.log
e PublishContentViews $logs/80-test-sync-repositories.log
e PromoteContentViews $logs/80-test-sync-repositories.log


section "Sync iso"
ap 81-test-sync-iso.log \
  -e "organization='{{ sat_org }}'" \
  -e "test_sync_iso_count='$test_sync_iso_count'" \
  -e "test_sync_iso_url_template='$test_sync_iso_url_template'" \
  -e "test_sync_iso_max_sync_secs='$test_sync_iso_max_sync_secs'" \
  playbooks/tests/sync-iso.yaml

e SyncRepositories $logs/81-test-sync-iso.log
e PublishContentViews $logs/81-test-sync-iso.log
e PromoteContentViews $logs/81-test-sync-iso.log


section "Sync docker repo"
ap 82-test-sync-docker.log \
  -e "organization='{{ sat_org }}'" \
  -e "test_sync_docker_count='$test_sync_docker_count'" \
  -e "test_sync_docker_url_template='$test_sync_docker_url_template'" \
  -e "test_sync_docker_max_sync_secs='$test_sync_docker_max_sync_secs'" \
  playbooks/tests/sync-docker.yaml

e SyncRepositories $logs/82-test-sync-docker.log
e PublishContentViews $logs/82-test-sync-docker.log
e PromoteContentViews $logs/82-test-sync-docker.log


section "Delete all content hosts"
ap 99-remove-hosts-if-any.log \
  playbooks/satellite/satellite-remove-hosts.yaml


section "Sosreport"
ap sosreporter-gatherer.log \
  -e "sosreport_gatherer_local_dir='../../$logs/sosreport/'" \
  playbooks/satellite/sosreport_gatherer.yaml


junit_upload
