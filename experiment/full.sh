#!/bin/bash

source experiment/run-library.sh

branch="${PARAM_branch:-satcpt}"
inventory="${PARAM_inventory:-conf/contperf/inventory.${branch}.ini}"
sat_version="${PARAM_sat_version:-stream}"

manifest_exercise_runs="${PARAM_manifest_exercise_runs:-5}"

rels="${PARAM_rels:-rhel6 rhel7 rhel8 rhel9 rhel10}"

lces="${PARAM_lces:-Test QA Pre Prod}"

basearch=x86_64

sat_client_product='Satellite Client'
repo_sat_client="${PARAM_repo_sat_client:-http://mirror.example.com}"

rhosp_product=RHOSP
rhosp_registry_url="https://${PARAM_rhosp_registry:-https://registry.example.io}"
rhosp_registry_username="${PARAM_rhosp_registry_username:-user}"
rhosp_registry_password="${PARAM_rhosp_registry_password:-password}"

flatpak_product=Flatpak
flatpak_remote=rhel
flatpak_remote_url="https://${PARAM_flatpak_remote:-https://flatpak.example.io}"
flatpak_remote_username="${PARAM_flatpak_remote_username:-user}"
flatpak_remote_password="${PARAM_flatpak_remote_password:-password}"

initial_expected_concurrent_registrations="${PARAM_initial_expected_concurrent_registrations:-32}"

profile="${PARAM_profile:-false}"

test_sync_repositories_count="${PARAM_test_sync_repositories_count:-8}"
test_sync_repositories_url_template="${PARAM_test_sync_repositories_url_template:-http://repos.example.com/repo*}"
test_sync_repositories_max_sync_secs="${PARAM_test_sync_repositories_max_sync_secs:-600}"
test_sync_repositories_le="${PARAM_test_sync_repositories_le:-test_sync_repositories_le}"
test_sync_iso_count="${PARAM_test_sync_iso_count:-8}"
test_sync_iso_url_template="${PARAM_test_sync_iso_url_template:-http://storage.example.com/iso-repos*}"
test_sync_iso_max_sync_secs="${PARAM_test_sync_iso_max_sync_secs:-600}"
test_sync_iso_le="${PARAM_test_sync_iso_le:-test_sync_iso_le}"
test_sync_docker_count="${PARAM_test_sync_docker_count:-8}"
test_sync_docker_url_template="${PARAM_test_sync_docker_url_template:-https://registry.example.io}"
test_sync_docker_max_sync_secs="${PARAM_test_sync_docker_max_sync_secs:-600}"
test_sync_docker_le="${PARAM_test_sync_docker_le:-test_sync_docker_le}"
test_sync_ansible_collections_count="${PARAM_test_sync_ansible_collections_count:-8}"
test_sync_ansible_collections_upstream_url_template="${PARAM_test_sync_ansible_collections_upstream_url_template:-https://galaxy.example.com/}"
test_sync_ansible_collections_max_sync_secs="${PARAM_test_sync_ansible_collections_max_sync_secs:-600}"
test_sync_ansible_collections_le="${PARAM_test_sync_ansible_collections_le:-test_sync_ansible_collections_le}"

rex_search_queries="${PARAM_rex_search_queries:-container110 container10 container0}"

ui_concurrency="${PARAM_ui_concurrency:-10}"
ui_duration="${PARAM_ui_duration:-300}"
ui_max_static_size="${PARAM_ui_max_static_size:-40960}"

opts="--forks 100 -i $inventory"
opts_adhoc="$opts"


section 'Checking environment'
generic_environment_check
# set +e


section 'Create base LCE(s), CCV(s) and AK(s)'
# LCE creation
prior=Library
for lce in $lces; do
    h "05-lce-create-${lce}.log" \
      "lifecycle-environment create --organization '{{ sat_org }}' --name '$lce' --prior '$prior'"

    prior=$lce
done

# CCV creation
for rel in $rels; do
    ccv="CCV_$rel"

    h "05-ccv-create-${rel}.log" \
      "content-view create --organization '{{ sat_org }}' --name '$ccv' --composite --auto-publish yes"
    h "05-ccv-publish-${rel}.log" \
      "content-view publish --organization '{{ sat_org }}' --name '$ccv'"

    # CCV promotion to LCE(s)
    prior=Library
    for lce in $lces; do
        h "05-ccv-promote-${rel}-${lce}.log" \
          "content-view version promote --organization '{{ sat_org }}' --content-view '$ccv' --from-lifecycle-environment '$prior' --to-lifecycle-environment '$lce'"

        prior=$lce
    done
done

# AK creation
unset aks
for rel in $rels; do
    ccv="CCV_$rel"

    prior=Library
    for lce in $lces; do
        ak="AK_${rel}_${lce}"
        aks+="$ak "

        h "05-ak-create-${rel}-${lce}.log" \
          "activation-key create --organization '{{ sat_org }}' --name '$ak' --content-view '$ccv' --lifecycle-environment '$lce'"

        prior=$lce
    done
done


section 'Prepare for Red Hat content'
test=00-manifest-test-download
skip_measurement=true apj $test \
  playbooks/tests/manifest_test_download.yaml

test=01-manifest-excercise
skip_measurement=true apj $test \
  -e runs=$manifest_exercise_runs \
  playbooks/tests/manifest_test.yaml
ej ManifestImport $test
ej ManifestRefresh $test
ej ManifestDelete $test

test=02-manifest-test-reimport
skip_measurement=true apj $test \
  playbooks/tests/manifest_test_reimport.yaml


section 'Sync OS from CDN'
for rel in $rels; do
    os_rel="${rel##rhel}"

    case $rel in
    rhel[67])
        os_releasever="${os_rel}Server"
        os_product='Red Hat Enterprise Linux Server'
        os_repo_name="Red Hat Enterprise Linux $os_rel Server RPMs $basearch $os_releasever"
        os_reposet_name="Red Hat Enterprise Linux $os_rel Server (RPMs)"
        if [[ "$rel" == 'rhel7' ]]; then
            os_extras_repo_name="Red Hat Enterprise Linux $os_rel Server - Extras RPMs $basearch"
            os_extras_reposet_name="Red Hat Enterprise Linux $os_rel Server - Extras (RPMs)"
        fi
        ;;
    rhel[89]|rhel10)
        os_releasever=$os_rel
        if [[ "$rel" != 'rhel10' ]]; then
            os_product="Red Hat Enterprise Linux for $basearch"
            os_repo_name="Red Hat Enterprise Linux $os_rel for $basearch - BaseOS RPMs $os_releasever"
            os_reposet_name="Red Hat Enterprise Linux $os_rel for $basearch - BaseOS (RPMs)"
            os_appstream_repo_name="Red Hat Enterprise Linux $os_rel for $basearch - AppStream RPMs $os_releasever"
            os_appstream_reposet_name="Red Hat Enterprise Linux $os_rel for $basearch - AppStream (RPMs)"
        else
            os_product="Red Hat Enterprise Linux for $basearch Beta"
            os_repo_name="Red Hat Enterprise Linux $os_rel for $basearch - BaseOS Beta RPMs"
            os_reposet_name="Red Hat Enterprise Linux $os_rel for $basearch - BaseOS Beta (RPMs)"
            os_appstream_repo_name="Red Hat Enterprise Linux $os_rel for $basearch - AppStream Beta RPMs"
            os_appstream_reposet_name="Red Hat Enterprise Linux $os_rel for $basearch - AppStream Beta (RPMs)"
        fi
        ;;
    esac

    case $rel in
    rhel[67])
        skip_measurement=true h "10-reposet-enable-${rel}.log" \
          "repository-set enable --organization '{{ sat_org }}' --product '$os_product' --name '$os_reposet_name' --releasever '$os_releasever' --basearch '$basearch'"
        h "12-repo-sync-${rel}.log" \
          "repository synchronize --organization '{{ sat_org }}' --product '$os_product' --name '$os_repo_name'"

        if [[ "$rel" == 'rhel7' ]]; then
            skip_measurement=true h "10-reposet-enable-${rel}extras.log" \
              "repository-set enable --organization '{{ sat_org }}' --product '$os_product' --name '$os_extras_reposet_name' --releasever '$os_releasever' --basearch '$basearch'"
            h "12-repo-sync-${rel}extras.log" \
              "repository synchronize --organization '{{ sat_org }}' --product '$os_product' --name '$os_extras_repo_name'"
        fi
        ;;
    rhel[89]|rhel10)
        skip_measurement=true h "10-reposet-enable-${rel}baseos.log" \
          "repository-set enable --organization '{{ sat_org }}' --product '$os_product' --name '$os_reposet_name' --releasever '$os_releasever' --basearch '$basearch'"
        h "12-repo-sync-${rel}baseos.log" \
          "repository synchronize --organization '{{ sat_org }}' --product '$os_product' --name '$os_repo_name'"

        skip_measurement=true h "10-reposet-enable-${rel}appstream.log" \
          "repository-set enable --organization '{{ sat_org }}' --product '$os_product' --name '$os_appstream_reposet_name' --releasever '$os_releasever' --basearch '$basearch'"
        h "12-repo-sync-${rel}appstream.log" \
          "repository synchronize --organization '{{ sat_org }}' --product '$os_product' --name '$os_appstream_repo_name'"
        ;;
    esac
done


section 'Create, publish and promote OS CVs / CCVs to LCE(s)s'
for rel in $rels; do
    ccv="CCV_$rel"
    os_rel="${rel##rhel}"

    case $rel in
    rhel[67])
        os_releasever="${os_rel}Server"
        os_product='Red Hat Enterprise Linux Server'
        os_repo_name="Red Hat Enterprise Linux $os_rel Server RPMs $basearch $os_releasever"
        os_rids="$( get_repo_id '{{ sat_org }}' "$os_product" "$os_repo_name" )"
        if [[ "$rel" == 'rhel7' ]]; then
            os_extras_repo_name="Red Hat Enterprise Linux $os_rel Server - Extras RPMs $basearch"
            os_rids="$os_rids,$( get_repo_id '{{ sat_org }}' "$os_product" "$os_extras_repo_name" )"
        fi
        ;;
    rhel[89]|rhel10)
        os_releasever=$os_rel
        if [[ "$rel" != 'rhel10' ]]; then
            os_product="Red Hat Enterprise Linux for $basearch"
            os_repo_name="Red Hat Enterprise Linux $os_rel for $basearch - BaseOS RPMs $os_releasever"
            os_appstream_repo_name="Red Hat Enterprise Linux $os_rel for $basearch - AppStream RPMs $os_releasever"
        else
            os_product="Red Hat Enterprise Linux for $basearch Beta"
            os_repo_name="Red Hat Enterprise Linux $os_rel for $basearch - BaseOS Beta RPMs"
            os_appstream_repo_name="Red Hat Enterprise Linux $os_rel for $basearch - AppStream Beta RPMs"
        fi
        os_rids="$( get_repo_id '{{ sat_org }}' "$os_product" "$os_repo_name" )"
        os_rids="$os_rids,$( get_repo_id '{{ sat_org }}' "$os_product" "$os_appstream_repo_name" )"
        ;;
    esac

    # OS CV
    cv_os="CV_$rel"

    h "13b-cv-create-${rel}-os.log" \
      "content-view create --organization '{{ sat_org }}' --name '$cv_os' --repository-ids '$os_rids'"
    h "13b-cv-publish-${rel}-os.log" \
      "content-view publish --organization '{{ sat_org }}' --name '$cv_os'"

    # CCV with OS
    h "13c-ccv-component-add-${rel}-os.log" \
      "content-view component add --organization '{{ sat_org }}' --composite-content-view '$ccv' --component-content-view '$cv_os' --latest"
    h "13c-ccv-publish-${rel}-os.log" \
      "content-view publish --organization '{{ sat_org }}' --name '$ccv'"

    # CCV promotion to LCE(s)
    prior=Library
    for lce in $lces; do
        h "13d-ccv-promote-${rel}-os-${lce}.log" \
          "content-view version promote --organization '{{ sat_org }}' --content-view '$ccv' --from-lifecycle-environment '$prior' --to-lifecycle-environment '$lce'"

        prior=$lce
    done
done


section 'Push OS content to capsules'
test=13-capsules-sync-os
skip_measurement=true ap ${test}.log \
  -e "organization='{{ sat_org }}'" \
  -e "lces='$lces'" \
  playbooks/tests/capsules-sync.yaml
e CapusuleSync "${logs}/${test}.log"


section 'Publish and promote big CV'
cv=BenchContentView
rids="$( get_repo_id '{{ sat_org }}' 'Red Hat Enterprise Linux Server' "Red Hat Enterprise Linux 6 Server RPMs $basearch 6Server" )"
rids="$rids,$( get_repo_id '{{ sat_org }}' 'Red Hat Enterprise Linux Server' "Red Hat Enterprise Linux 7 Server RPMs $basearch 7Server" )"
rids="$rids,$( get_repo_id '{{ sat_org }}' 'Red Hat Enterprise Linux Server' "Red Hat Enterprise Linux 7 Server - Extras RPMs $basearch" )"

skip_measurement=true h 20-cv-create-big.log \
  "content-view create --organization '{{ sat_org }}' --repository-ids '$rids' --name '$cv'"
h 21-cv-publish-big.log \
  "content-view publish --organization '{{ sat_org }}' --name '$cv'"

prior=Library
counter=1
for lce in BenchLifeEnvAAA BenchLifeEnvBBB BenchLifeEnvCCC; do
    skip_measurement=true h "22-le-create-${prior}-${lce}.log" \
      "lifecycle-environment create --organization '{{ sat_org }}' --prior '$prior' --name '$lce'"
    h "23-cv-promote-big-${prior}-${lce}.log" \
      "content-view version promote --organization '{{ sat_org }}' --content-view '$cv' --to-lifecycle-environment '$prior' --to-lifecycle-environment '$lce'"

    prior=$lce
    (( counter++ ))
done


section 'Publish and promote filtered CV'
export skip_measurement=true
cv=BenchFilteredContentView
rids="$( get_repo_id '{{ sat_org }}' 'Red Hat Enterprise Linux Server' "Red Hat Enterprise Linux 6 Server RPMs $basearch 6Server" )"

h 30-cv-create-filtered.log \
  "content-view create --organization '{{ sat_org }}' --repository-ids '$rids' --name '$cv'"

h 31-filter-create-1.log \
  "content-view filter create --organization '{{ sat_org }}' --type erratum --inclusion true --content-view '$cv' --name BenchFilterAAA"
h 31-filter-create-2.log \
  "content-view filter create --organization '{{ sat_org }}' --type erratum --inclusion true --content-view '$cv' --name BenchFilterBBB"

h 32-rule-create-1.log \
  "content-view filter rule create --content-view '$cv' --content-view-filter BenchFilterAAA --date-type 'issued' --start-date 2016-01-01 --end-date 2017-10-01 --organization '{{ sat_org }}' --types enhancement,bugfix,security"
h 32-rule-create-2.log \
  "content-view filter rule create --content-view '$cv' --content-view-filter BenchFilterBBB --date-type 'updated' --start-date 2016-01-01 --end-date 2018-01-01 --organization '{{ sat_org }}' --types security"
unset skip_measurement

h 33-cv-filtered-publish.log \
  "content-view publish --organization '{{ sat_org }}' --name '$cv'"


export skip_measurement=true
section 'Get Satellite Client content'
# Satellite Client
h 30-product-create-sat-client.log \
  "product create --organization '{{ sat_org }}' --name '$sat_client_product'"

for rel in $rels; do
    ccv="CCV_${rel}"
    os_rel="${rel##rhel}"
    sat_client_repo_name="Satellite Client for RHEL $os_rel"
    sat_client_repo_url="${repo_sat_client}/Satellite_Client_RHEL${os_rel}_${basearch}/"

    h "30-repository-create-sat-client_${rel}.log" \
      "repository create --organization '{{ sat_org }}' --product '$sat_client_product' --name '$sat_client_repo_name' --content-type yum --url '$sat_client_repo_url'"
    h "30-repository-sync-sat-client_${rel}.log" \
      "repository synchronize --organization '{{ sat_org }}' --product '$sat_client_product' --name '$sat_client_repo_name'"

    sat_client_rids="$( get_repo_id '{{ sat_org }}' "$sat_client_product" "$sat_client_repo_name" )"
    content_label="$( h_out "--no-headers --csv repository list --organization '{{ sat_org }}' --search 'name = \"$sat_client_repo_name\"' --fields 'Content label'" | tail -n1 )"

    # Satellite Client CV
    cv_sat_client="CV_${rel}-sat-client"

    h "34-cv-create-${rel}-sat-client.log" \
      "content-view create --organization '{{ sat_org }}' --name '$cv_sat_client' --repository-ids '$sat_client_rids'"

    h "35-cv-publish-${rel}-sat-client.log" \
      "content-view publish --organization '{{ sat_org }}' --name '$cv_sat_client'"

    # CCV with Satellite Client
    h "36-ccv-component-add-${rel}-sat-client.log" \
      "content-view component add --organization '{{ sat_org }}' --composite-content-view '$ccv' --component-content-view '$cv_sat_client' --latest"
    h "37-ccv-publish-${rel}-sat-client.log" \
      "content-view publish --organization '{{ sat_org }}' --name '$ccv'"

    prior=Library
    for lce in $lces; do
        ak="AK_${rel}_${lce}"

        # CCV promotion to LCE
        h "38-ccv-promote-${rel}-${lce}.log" \
          "content-view version promote --organization '{{ sat_org }}' --content-view '$ccv' --from-lifecycle-environment '$prior' --to-lifecycle-environment '$lce'"

        # Enable 'Satellite Client' repo in AK
        id="$( h_out "--no-headers --csv activation-key list --organization '{{ sat_org }}' --search 'name = \"$ak\"' --fields id"  | tail -n1 )"
        h "39-ak-content-override-${rel}-${lce}.log" \
          "activation-key content-override --organization '{{ sat_org }}' --id $id --content-label $content_label --value true"

        prior=$lce
    done
done
unset skip_measurement


section 'Push Satellite Client content to capsules'
test=38-capsules-sync-sat-client
skip_measurement=true ap ${test}.log \
  -e "organization='{{ sat_org }}'" \
  -e "lces='$lces'" \
  playbooks/tests/capsules-sync.yaml
e CapusuleSync "${logs}/${test}.log"


export skip_measurement=true
section 'Get RHOSP content'
# RHOSP
h 40-product-create-rhosp.log \
  "product create --organization '{{ sat_org }}' --name '$rhosp_product'"

for rel in $rels; do
    ccv="CCV_${rel}"

    case $rel in
    rhel[89])
    # rhel[89]|rhel10)
        rhsop_repo_name="rhosp-${rel}/openstack-base"

        h "40-repository-create-rhosp-${rel}_openstack-base.log" \
          "repository create --organization '{{ sat_org }}' --product '$rhosp_product' --name '$rhsop_repo_name' --content-type docker --url '$rhosp_registry_url' --docker-upstream-name '$rhsop_repo_name' --upstream-username '$rhosp_registry_username' --upstream-password '$rhosp_registry_password'"
        h "40-repository-sync-rhosp-${rel}_openstack-base.log" \
          "repository synchronize --organization '{{ sat_org }}' --product '$rhosp_product' --name '$rhsop_repo_name'"

        rhosp_rids="$( get_repo_id '{{ sat_org }}' "$rhosp_product" "$rhsop_repo_name" )"
        content_label="$( h_out "--no-headers --csv repository list --organization '{{ sat_org }}' --search 'name = \"$rhosp_rids\"' --fields 'Content label'" | tail -n1 )"

        # RHOSP CV
        cv_osp="CV_${rel}-osp"

        h "40-cv-create-rhosp-${rel}.log" \
          "content-view create --organization '{{ sat_org }}' --name '$cv_osp' --repository-ids '$rhosp_rids'"
        h "40-cv-publish-rhosp-${rel}.log" \
          "content-view publish --organization '{{ sat_org }}' --name '$cv_osp'"

        # CCV with RHOSP
        h "40-ccv-component-add-rhosp-${rel}.log" \
          "content-view component add --organization '{{ sat_org }}' --composite-content-view '$ccv' --component-content-view '$cv_osp' --latest"
        h "40-ccv-publish-rhosp-${rel}.log" \
          "content-view publish --organization '{{ sat_org }}' --name '$ccv'"

        prior=Library
        for lce in $lces; do
            ak="AK_${rel}_${lce}"

            # CCV promotion to LCE
            h "40-ccv-promote-rhosp-${rel}-${lce}.log" \
              "content-view version promote --organization '{{ sat_org }}' --content-view '$ccv' --from-lifecycle-environment '$prior' --to-lifecycle-environment '$lce'"

            prior=$lce
        done
        ;;
    esac
done
unset skip_measurement


section 'Push RHOSP content to capsules'
test=40-capsules-sync-rhosp
skip_measurement=true ap ${test}.log \
  -e "organization='{{ sat_org }}'" \
  -e "lces='$lces'" \
  playbooks/tests/capsules-sync.yaml
e CapusuleSync "${logs}/${test}.log"


if vercmp_ge "$sat_version" '6.17.0'; then
    section 'Get Flatpak content'
    # Flatpak
    product="$flatpak_product"

    h "45-product-create-${product}.log" \
      "product create --organization '{{ sat_org }}' --name '$product'"

    h "45-flatpak-remote-create-${flatpak_remote}.log" \
      "flatpak-remote create --organization '{{ sat_org }}' --name '$flatpak_remote' --url '${flatpak_remote_url}/${flatpak_remote}' --username '$flatpak_remote_username' --token '$flatpak_remote_password'"

    h "45-flatpak-remote-scan-${flatpak_remote}.log" \
      "flatpak-remote scan --organization '{{ sat_org }}' --name '$flatpak_remote'"

    h "45-flatpak-remote-remote-repository-list-${flatpak_remote}.log" \
      "flatpak-remote remote-repository list --organization '{{ sat_org }}' --flatpak-remote '$flatpak_remote'"

    for rel in $rels; do
        ccv="CCV_${rel}"

        case $rel in
        rhel[89])
        # rhel[89]|rhel10)
            repo_name="${rel}/flatpak-runtime"
            repo_name_suffix="$(echo ${repo_name} | tr '/' '_')"

            h "45-flatpak-remote-remote-repository-mirror-${repo_name_suffix}.log" \
              "flatpak-remote remote-repository mirror --organization '{{ sat_org }}' --product '$product' --flatpak-remote '$flatpak_remote' --name '$repo_name'"

            h "45-repository-sync-${repo_name_suffix}.log" \
              "repository synchronize --organization '{{ sat_org }}' --product '$product' --name '$repo_name'"

            # CV
            cv="CV_${rel}-${product}"
            rids="$( get_repo_id '{{ sat_org }}' "$product" "$repo_name" )"
            content_label="$( h_out "--no-headers --csv repository list --organization '{{ sat_org }}' --search 'name = \"$repo_name\"' --fields 'Content label'" | tail -n1 )"

            h "45-cv-create-${rel}-flatpak.log" \
              "content-view create --organization '{{ sat_org }}' --name '$cv' --repository-ids '$rids'"
            h "45-cv-publish-${rel}-flatpak.log" \
              "content-view publish --organization '{{ sat_org }}' --name '$cv'"

            # CCV with Flatpak
            h "45-ccv-component-add-${rel}-flatpak.log" \
              "content-view component add --organization '{{ sat_org }}' --composite-content-view '$ccv' --component-content-view '$cv' --latest"
            h "45-ccv-publish-${rel}-flatpak.log" \
              "content-view publish --organization '{{ sat_org }}' --name '$ccv'"

            prior=Library
            for lce in $lces; do
                ak="AK_${rel}_${lce}"

                # CCV promotion to LCE
                h "45-ccv-promote-${rel}-${lce}-flatpak.log" \
                  "content-view version promote --organization '{{ sat_org }}' --content-view '$ccv' --from-lifecycle-environment '$prior' --to-lifecycle-environment '$lce'"

                prior=$lce
            done
            ;;
        esac
    done


    section 'Push Flatpak content to capsules'
    test=45-capsules-sync-flatpak
    skip_measurement=true ap ${test}.log \
      -e "organization='{{ sat_org }}'" \
      -e "lces='$lces'" \
      playbooks/tests/capsules-sync.yaml
    e CapusuleSync "${logs}/${test}.log"
fi


section 'Sync yum repo'
test=80-test-sync-repositories
skip_measurement=true ap ${test}.log \
  -e "organization='{{ sat_org }}'" \
  -e "test_sync_repositories_count='$test_sync_repositories_count'" \
  -e "test_sync_repositories_url_template='$test_sync_repositories_url_template'" \
  -e "test_sync_repositories_max_sync_secs='$test_sync_repositories_max_sync_secs'" \
  -e "test_sync_repositories_le='$test_sync_repositories_le'" \
  playbooks/tests/sync-repositories.yaml
e SyncRepositories "${logs}/${test}.log"
e PublishContentViews "${logs}/${test}.log"
e PromoteContentViews "${logs}/${test}.log"


section 'Push yum content to capsules'
test=80-capsules-sync-repositories
skip_measurement=true ap ${test}.log \
  -e "organization='{{ sat_org }}'" \
  -e "lces='$test_sync_repositories_le'" \
  playbooks/tests/capsules-sync.yaml
e CapusuleSync "${logs}/${test}.log"


section 'Sync iso'
test=81-test-sync-iso
skip_measurement=true ap ${test}.log \
  -e "organization='{{ sat_org }}'" \
  -e "test_sync_iso_count='$test_sync_iso_count'" \
  -e "test_sync_iso_url_template='$test_sync_iso_url_template'" \
  -e "test_sync_iso_max_sync_secs='$test_sync_iso_max_sync_secs'" \
  -e "test_sync_iso_le='$test_sync_iso_le'" \
  playbooks/tests/sync-iso.yaml
e SyncRepositories "${logs}/${test}.log"
e PublishContentViews "${logs}/${test}.log"
e PromoteContentViews "${logs}/${test}.log"


section 'Push iso content to capsules'
test=81-capsules-sync-iso
skip_measurement=true ap ${test}.log \
  -e "organization='{{ sat_org }}'" \
  -e "lces='$test_sync_iso_le'" \
  playbooks/tests/capsules-sync.yaml
e CapusuleSync "${logs}/${test}.log"


section 'Sync docker repo'
test=82-test-sync-docker
skip_measurement=true ap ${test}.log \
  -e "organization='{{ sat_org }}'" \
  -e "test_sync_docker_count='$test_sync_docker_count'" \
  -e "test_sync_docker_url_template='$test_sync_docker_url_template'" \
  -e "test_sync_docker_max_sync_secs='$test_sync_docker_max_sync_secs'" \
  -e "test_sync_docker_le='$test_sync_docker_le'" \
  playbooks/tests/sync-docker.yaml
e SyncRepositories "${logs}/${test}.log"
e PublishContentViews "${logs}/${test}.log"
e PromoteContentViews "${logs}/${test}.log"


section 'Push docker content to capsules'
test=82-capsules-sync-docker
skip_measurement=true ap ${test}.log \
  -e "organization='{{ sat_org }}'" \
  -e "lces='$test_sync_docker_le'" \
  playbooks/tests/capsules-sync.yaml
e CapusuleSync "${logs}/${test}.log"


section 'Sync ansible collections'
test=83-test-sync-ansible-collections
skip_measurement=true ap ${test}.log \
  -e "organization='{{ sat_org }}'" \
  -e "test_sync_ansible_collections_count='$test_sync_ansible_collections_count'" \
  -e "test_sync_ansible_collections_upstream_url_template='$test_sync_ansible_collections_upstream_url_template'" \
  -e "test_sync_ansible_collections_max_sync_secs='$test_sync_ansible_collections_max_sync_secs'" \
  -e "test_sync_ansible_collections_le='$test_sync_ansible_collections_le'" \
  playbooks/tests/sync-ansible-collections.yaml
e SyncRepositories "${logs}/${test}.log"
e PublishContentViews "${logs}/${test}.log"
e PromoteContentViews "${logs}/${test}.log"


section 'Push ansible collections content to capsules'
test=83-capsules-sync-ansible-collections
skip_measurement=true ap ${test}.log \
  -e "organization='{{ sat_org }}'" \
  -e "lces='$test_sync_ansible_collections_le'" \
  playbooks/tests/capsules-sync.yaml
e CapusuleSync "${logs}/${test}.log"


export skip_measurement=true
section 'Prepare for registrations'
h_out "--no-headers --csv domain list --search 'name = {{ domain }}'" | grep --quiet '^[0-9]\+,' ||
  h 42-domain-create.log \
  "domain create --name '{{ domain }}' --organizations '{{ sat_org }}'"

tmp="$( mktemp )"
h_out "--no-headers --csv location list --organization '{{ sat_org }}'" | grep '^[0-9]\+,' >"$tmp"
location_ids="$( cut -d ',' -f 1 "$tmp" | tr '\n' ',' | sed 's/,$//' )"
rm -f "$tmp"

h 42-domain-update.log \
  "domain update --name '{{ domain }}' --organizations '{{ sat_org }}' --location-ids '$location_ids'"

ap 44-generate-host-registration-commands.log \
  -e "organization='{{ sat_org }}'" \
  -e "aks='$aks'" \
  -e "sat_version='$sat_version'" \
  playbooks/satellite/host-registration_generate-commands.yaml

ap 44-recreate-client-scripts.log \
  -e "aks='$aks'" \
  -e "sat_version='$sat_version'" \
  playbooks/satellite/client-scripts.yaml
unset skip_measurement


section 'Incremental registrations'
number_container_hosts="$( ansible $opts_adhoc --list-hosts container_hosts 2>/dev/null | grep -cv '^  hosts' )"
number_containers_per_container_host="$( ansible $opts_adhoc -m ansible.builtin.debug -a "var=containers_count" container_hosts[0] | awk '/    "containers_count":/ {print $NF}' )"
if (( initial_expected_concurrent_registrations > number_container_hosts )); then
    initial_concurrent_registrations_per_container_host="$(( initial_expected_concurrent_registrations / number_container_hosts ))"
else
    initial_concurrent_registrations_per_container_host=1
fi
num_retry_forks="$(( initial_expected_concurrent_registrations / number_container_hosts ))"
prefix=48-register

for (( batch=1, remaining_containers_per_container_host=number_containers_per_container_host, total_registered=0; remaining_containers_per_container_host > 0; batch++ )); do
    if (( remaining_containers_per_container_host > initial_concurrent_registrations_per_container_host * batch )); then
        concurrent_registrations_per_container_host="$(( initial_concurrent_registrations_per_container_host * batch ))"
    else
        concurrent_registrations_per_container_host=$remaining_containers_per_container_host
    fi
    concurrent_registrations="$(( concurrent_registrations_per_container_host * number_container_hosts ))"
    (( remaining_containers_per_container_host -= concurrent_registrations_per_container_host ))
    (( total_registered += concurrent_registrations ))
    test="$prefix-${concurrent_registrations}"

    log "Trying to register $concurrent_registrations content hosts concurrently in this batch"

    skip_measurement=true ap ${test}.log \
      -e "size='$concurrent_registrations_per_container_host'" \
      -e "concurrent_registrations='$concurrent_registrations'" \
      -e "num_retry_forks='$num_retry_forks'" \
      -e "registration_logs='../../$logs/$prefix-container-host-client-logs'" \
      -e 're_register_failed_hosts=true' \
      -e "sat_version='$sat_version'" \
      -e "profile='$profile'" \
      -e "registration_profile_img='$test.svg'" \
      playbooks/tests/registrations.yaml
      e Register "${logs}/${test}.log"
done
grep Register "$logs"/$prefix-*.log >"$logs/$prefix-overall.log"
e Register "$logs/$prefix-overall.log"


section 'Misc simple tests'
test=50-hammer-list
skip_measurement=true ap ${test}.log \
  -e "organization='{{ sat_org }}'" \
  playbooks/tests/hammer-list.yaml
e HammerHostList "${logs}/${test}.log"

rm -f /tmp/status-data-webui-pages.json
test=51-webui-pages
skip_measurement=true ap ${test}.log \
  -e "sat_version='$sat_version'" \
  -e "ui_concurrency='$ui_concurrency'" \
  -e "ui_duration='$ui_duration'" \
  playbooks/tests/webui-pages.yaml
STATUS_DATA_FILE=/tmp/status-data-webui-pages.json e "WebUIPagesTest_c${ui_concurrency}_d${ui_duration}" "${logs}/${test}.log"

rm -f /tmp/status-data-webui-static-distributed.json
test=52-webui-static-distributed
skip_measurement=true ap ${test}.log \
  -e "sat_version='$sat_version'" \
  -e "ui_concurrency='$ui_concurrency'" \
  -e "ui_duration='$ui_duration'" \
  -e "ui_max_static_size='$ui_max_static_size'" \
  playbooks/tests/webui-static-distributed.yaml
STATUS_DATA_FILE=/tmp/status-data-webui-static-distributed.json e "WebUIStaticDistributedTest_c${ui_concurrency}_d${ui_duration}" "${logs}/${test}.log"

a 53-foreman_inventory_upload-report-generate.log \
  -m ansible.builtin.shell \
  -a "export organization='{{ sat_org }}'; export target=/var/lib/foreman/red_hat_inventory/generated_reports/; /usr/sbin/foreman-rake rh_cloud_inventory:report:generate" \
  satellite6


section 'BackupTest'
test=55-backup
skip_measurement=true ap ${test}.log \
  playbooks/tests/sat-backup.yaml
e BackupOffline "${logs}/${test}.log"
e RestoreOffline "${logs}/${test}.log"
e BackupOnline "${logs}/${test}.log"
e RestoreOnline "${logs}/${test}.log"


section 'Remote execution (ReX)'
job_template_ansible_default='Run Command - Ansible Default'
job_template_ssh_default='Run Command - Script Default'

skip_measurement=true h 58-rex-set-via-ip.log \
  "settings set --name remote_execution_connect_by_ip --value true"
skip_measurement=true a 59-rex-cleanup-know_hosts.log \
  -m ansible.builtin.shell \
  -a "rm -rf /usr/share/foreman-proxy/.ssh/known_hosts*" \
  satellite6

for rex_search_query in $rex_search_queries; do
    num_matching_rex_hosts="$(h_out "--no-headers --csv host list --organization '{{ sat_org }}' --thin true --search 'name ~ $rex_search_query'" | grep -c "$rex_search_query")"

    if (( num_matching_rex_hosts > 0 )); then
      test=60-rex-date-${num_matching_rex_hosts}
      skip_measurement=true h ${test}.log \
        "job-invocation create --async --description-format '${num_matching_rex_hosts} hosts - Run %{command} (%{template_name})' --inputs command='date' --job-template '$job_template_ssh_default' --search-query 'name ~ $rex_search_query'"
      jsr "${logs}/${test}.log"
      j "${logs}/${test}.log"

      test=61-rex-date-ansible-${num_matching_rex_hosts}
      skip_measurement=true h ${test}.log \
        "job-invocation create --async --description-format '${num_matching_rex_hosts} hosts - Run %{command} (%{template_name})' --inputs command='date' --job-template '$job_template_ansible_default' --search-query 'name ~ $rex_search_query'"
      jsr "${logs}/${test}.log"
      j "${logs}/${test}.log"

      test=62-rex-katello_package_install-podman-${num_matching_rex_hosts}
      skip_measurement=true h ${test}.log \
        "job-invocation create --async --description-format '${num_matching_rex_hosts} hosts - Install %{package} (%{template_name})' --feature katello_package_install --inputs package='podman' --search-query 'name ~ $rex_search_query'"
      jsr "${logs}/${test}.log"
      j "${logs}/${test}.log"

      test=62-rex-podman_pull-${num_matching_rex_hosts}
      skip_measurement=true h ${test}.log \
        "job-invocation create --async --description-format '${num_matching_rex_hosts} hosts - Run %{command} (%{template_name})' --inputs command='bash -x /root/podman-pull.sh' --job-template '$job_template_ssh_default' --search-query 'name ~ $rex_search_query'"
      jsr "${logs}/${test}.log"
      j "${logs}/${test}.log"

      test=65-rex-katello_package_update-${num_matching_rex_hosts}
      skip_measurement=true h ${test}.log \
        "job-invocation create --async --description-format '${num_matching_rex_hosts} hosts - (%{template_name})' --feature katello_package_update --search-query 'name ~ $rex_search_query'"
      jsr "${logs}/${test}.log"
      j "${logs}/${test}.log"
    fi
done


if vercmp_ge "$sat_version" '6.17.0'; then
    section 'Generate satellite-maintain report'
    as 95-satellite-maintain_report_generate.log \
      'satellite-maintain report generate'
fi


section 'Delete all content hosts'
ap 99-remove-hosts-if-any.log \
  playbooks/satellite/satellite-remove-hosts.yaml


section 'Delete base LCE(s), CCV(s) and AK(s)'
# AK deletion
for rel in $rels; do
    for lce in $lces; do
        ak="AK_${rel}_${lce}"

        h "100-ak-delete-${rel}-${lce}.log" \
          "activation-key delete --organization '{{ sat_org }}' --name '$ak'"
    done
done

# LCE deletion
for lce in $lces; do
    h "101-lce-delete-${lce}.log" \
      "lifecycle-environment delete --organization '{{ sat_org }}' --name '$lce'"
done

# CVV deletion
for rel in $rels; do
    ccv="CCV_$rel"

    h "102-ccv-delete-${rel}.log" \
      "content-view delete --organization '{{ sat_org }}' --name '$ccv'"
done

# Repository deletion
for os_rid in $os_rids; do
    h "103-repository-delete-${os_rid}.log" \
      "repository delete --organization '{{ sat_org }}' --name '$os_rid'"
done

# Product deletion
# Satellite Client
h 104-product-delete-sat-client.log \
  "product delete --organization '{{ sat_org }}' --name '$sat_client_product'"
# RHOSP
h 104-product-delete-rhosp.log \
  "product delete --organization '{{ sat_org }}' --name '$rhosp_product'"
if vercmp_ge "$sat_version" '6.17.0'; then
    # Flatpak
    h 104-product-delete-flatpak.log \
      "product delete --organization '{{ sat_org }}' --name '$flatpak_product'"
fi


section 'Sosreport'
skip_measurement=true ap sosreporter-gatherer.log \
  -e "sosreport_gatherer_local_dir='../../$logs/sosreport/'" \
  playbooks/satellite/sosreport_gatherer.yaml


junit_upload
