#!/bin/bash

source experiment/run-library.sh

branch="${PARAM_branch:-satcpt}"
inventory="${PARAM_inventory:-conf/contperf/inventory.${branch}.ini}"
sat_version="${PARAM_sat_version:-stream}"
manifest="${PARAM_manifest:-conf/contperf/manifest.zip}"

rels="${PARAM_rels:-rhel8 rhel9 rhel10}"

lces="${PARAM_lces:-Test}"

basearch=x86_64

sat_client_product='Satellite Client'
repo_sat_client="${PARAM_repo_sat_client:-http://mirror.example.com}"

rhosp_product=RHOSP
rhosp_registry_url="https://${PARAM_rhosp_registry:-https://registry.example.io}"
rhosp_registry_username="${PARAM_rhosp_registry_username:-user}"
rhosp_registry_password="${PARAM_rhosp_registry_password:-password}"

skip_down_setup="${PARAM_skip_down_setup:-false}"

skip_push_to_capsules_setup="${PARAM_skip_push_to_capsules_setup:-false}"
capsule_download_policy="${PARAM_capsule_download_policy:-inherit}"

initial_expected_concurrent_registrations="${PARAM_initial_expected_concurrent_registrations:-32}"

profile="${PARAM_profile:-false}"

opts="--forks 100 -i $inventory"
opts_adhoc="$opts"


section 'Checking environment'
generic_environment_check
# set +e


export skip_measurement=true

if ! $skip_down_setup; then
    section 'Create base LCE(s), CCV(s) and AK(s)'
    # LCE creation
    prior=Library
    for lce in $lces; do
        h "01-lce-create-${lce}.log" \
          "lifecycle-environment create --organization '{{ sat_org }}' --name '$lce' --prior '$prior'"

        prior=$lce
    done

    # CCV creation
    for rel in $rels; do
        ccv="CCV_$rel"

        h "06-ccv-create-${rel}.log" \
          "content-view create --organization '{{ sat_org }}' --name '$ccv' --composite --auto-publish yes"
        h "06-ccv-publish-${rel}.log" \
          "content-view publish --organization '{{ sat_org }}' --name '$ccv'"

        # CCV promotion to LCE(s)
        prior=Library
        for lce in $lces; do
            h "06-ccv-promote-${rel}-${lce}.log" "content-view version promote --organization '{{ sat_org }}' --content-view '$ccv' --from-lifecycle-environment '$prior' --to-lifecycle-environment '$lce'"

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

            h "07-ak-create-${rel}-${lce}.log" \
              "activation-key create --organization '{{ sat_org }}' --name '$ak' --content-view '$ccv' --lifecycle-environment '$lce'"

            prior=$lce
        done
    done


    section 'Upload manifest'
    a 09-manifest-deploy.log \
      -m ansible.builtin.copy \
      -a "src=$manifest dest=/root/manifest-auto.zip force=yes" \
      satellite6
    h 09-manifest-upload.log \
      "subscription upload --file '/root/manifest-auto.zip' --organization '{{ sat_org }}'"
    h 09-manifest-refresh.log \
      "subscription refresh-manifest --organization '{{ sat_org }}'"


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
            h "12-reposet-enable-${rel}.log" \
              "repository-set enable --organization '{{ sat_org }}' --product '$os_product' --name '$os_reposet_name' --releasever '$os_releasever' --basearch '$basearch'"
            h "13-repo-sync-${rel}.log" \
              "repository synchronize --organization '{{ sat_org }}' --product '$os_product' --name '$os_repo_name'"

            if [[ "$rel" == 'rhel7' ]]; then
                h "12-reposet-enable-${rel}extras.log" \
                  "repository-set enable --organization '{{ sat_org }}' --product '$os_product' --name '$os_extras_reposet_name' --releasever '$os_releasever' --basearch '$basearch'"
                h "13-repo-sync-${rel}extras.log" \
                  "repository synchronize --organization '{{ sat_org }}' --product '$os_product' --name '$os_extras_repo_name'"
            fi
            ;;
        rhel[89]|rhel10)
            h "12-reposet-enable-${rel}baseos.log" \
              "repository-set enable --organization '{{ sat_org }}' --product '$os_product' --name '$os_reposet_name' --releasever '$os_releasever' --basearch '$basearch'"
            h "13-repo-sync-${rel}baseos.log" \
              "repository synchronize --organization '{{ sat_org }}' --product '$os_product' --name '$os_repo_name'"

            h "12-reposet-enable-${rel}appstream.log" \
              "repository-set enable --organization '{{ sat_org }}' --product '$os_product' --name '$os_appstream_reposet_name' --releasever '$os_releasever' --basearch '$basearch'"
            h "13-repo-sync-${rel}appstream.log" \
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

        h "15-cv-create-${rel}-os.log" \
          "content-view create --organization '{{ sat_org }}' --name '$cv_os' --repository-ids '$os_rids'"
        h "15-cv-publish-${rel}-os.log" \
          "content-view publish --organization '{{ sat_org }}' --name '$cv_os'"

        # CCV with OS
        h "16-ccv-component-add-${rel}-os.log" \
          "content-view component add --organization '{{ sat_org }}' --composite-content-view '$ccv' --component-content-view '$cv_os' --latest"
        h "16-ccv-publish-${rel}-os.log" \
          "content-view publish --organization '{{ sat_org }}' --name '$ccv'"

        # CCV promotion to LCE(s)
        prior=Library
        for lce in $lces; do
            h "16-ccv-promote-${rel}-os-${lce}.log" \
              "content-view version promote --organization '{{ sat_org }}' --content-view '$ccv' --from-lifecycle-environment '$prior' --to-lifecycle-environment '$lce'"

            prior=$lce
        done
    done

    section 'Get Satellite Client content'
    # Satellite Client
    h 30-sat-client-product-create.log \
      "product create --organization '{{ sat_org }}' --name '$sat_client_product'"

    for rel in $rels; do
        ccv="CCV_${rel}"
        os_rel="${rel##rhel}"
        sat_client_repo_name="Satellite Client for RHEL $os_rel"
        sat_client_repo_url="${repo_sat_client}/Satellite_Client_RHEL${os_rel}_${basearch}/"

        h "32-repository-create-sat-client_${rel}.log" \
          "repository create --organization '{{ sat_org }}' --product '$sat_client_product' --name '$sat_client_repo_name' --content-type yum --url '$sat_client_repo_url'"
        h "33-repository-sync-sat-client_${rel}.log" \
          "repository synchronize --organization '{{ sat_org }}' --product '$sat_client_product' --name '$sat_client_repo_name'"

        sat_client_rids="$( get_repo_id '{{ sat_org }}' "$sat_client_product" "$sat_client_repo_name" )"
        content_label="$( h_out "--no-headers --csv repository list --organization '{{ sat_org }}' --search 'name = \"$sat_client_repo_name\"' --fields 'Content label'" | tail -n1 )"

        # Satellite Client CV
        cv_sat_client="CV_${rel}-sat-client"

        h "35-cv-create-${rel}-sat-client.log" \
          "content-view create --organization '{{ sat_org }}' --name '$cv_sat_client' --repository-ids '$sat_client_rids'"

        h "35-cv-publish-${rel}-sat-client.log" \
          "content-view publish --organization '{{ sat_org }}' --name '$cv_sat_client'"

        # CCV with Satellite Client
        h "36-ccv-component-add-${rel}-sat-client.log" \
          "content-view component add --organization '{{ sat_org }}' --composite-content-view '$ccv' --component-content-view '$cv_sat_client' --latest"
        h "36-ccv-publish-${rel}-sat-client.log" \
          "content-view publish --organization '{{ sat_org }}' --name '$ccv'"

        prior=Library
        for lce in $lces; do
            ak="AK_${rel}_${lce}"

            # CCV promotion to LCE
            h "36-ccv-promote-${rel}-${lce}.log" \
              "content-view version promote --organization '{{ sat_org }}' --content-view '$ccv' --from-lifecycle-environment '$prior' --to-lifecycle-environment '$lce'"

            # Enable 'Satellite Client' repo in AK
            id="$( h_out "--no-headers --csv activation-key list --organization '{{ sat_org }}' --search 'name = \"$ak\"' --fields id"  | tail -n1 )"
            h "37-ak-content-override-${rel}-${lce}.log" \
              "activation-key content-override --organization '{{ sat_org }}' --id $id --content-label $content_label --value true"

            prior=$lce
        done
    done


    section 'Get RHOSP content'
    # RHOSP
    h 40-product-create-rhsop.log \
      "product create --organization '{{ sat_org }}' --name '$rhosp_product'"

    for rel in $rels; do
        ccv="CCV_${rel}"

        case $rel in
        rhel[89])
        # rhel[89]|rhel10)
            rhsop_repo_name="rhosp-${rel}/openstack-base"

            h "42-repository-create-rhosp-${rel}_openstack-base.log" \
              "repository create --organization '{{ sat_org }}' --product '$rhosp_product' --name '$rhsop_repo_name' --content-type docker --url '$rhosp_registry_url' --docker-upstream-name '$rhsop_repo_name' --upstream-username '$rhosp_registry_username' --upstream-password '$rhosp_registry_password'"
            h "43-repository-sync-rhosp-${rel}_openstack-base.log" \
              "repository synchronize --organization '{{ sat_org }}' --product '$rhosp_product' --name '$rhsop_repo_name'"

            rhosp_rids="$( get_repo_id '{{ sat_org }}' "$rhosp_product" "$rhsop_repo_name" )"
            content_label="$( h_out "--no-headers --csv repository list --organization '{{ sat_org }}' --search 'name = \"$rhosp_rids\"' --fields 'Content label'" | tail -n1 )"

            # RHOSP CV
            cv_osp="CV_${rel}-osp"

            h "45-cv-create-rhosp-${rel}.log" \
              "content-view create --organization '{{ sat_org }}' --name '$cv_osp' --repository-ids '$rhosp_rids'"

            h "45-cv-publish-rhosp-${rel}.log" \
              "content-view publish --organization '{{ sat_org }}' --name '$cv_osp'"

            # CCV with RHOSP
            h "46-ccv-component-add-rhosp-${rel}.log" \
              "content-view component add --organization '{{ sat_org }}' --composite-content-view '$ccv' --component-content-view '$cv_osp' --latest"
            h "46-ccv-publish-rhosp-${rel}.log" \
              "content-view publish --organization '{{ sat_org }}' --name '$ccv'"

            prior=Library
            for lce in $lces; do
                ak="AK_${rel}_${lce}"

                # CCV promotion to LCE
                h "46-ccv-promote-rhosp-${rel}-${lce}.log" \
                  "content-view version promote --organization '{{ sat_org }}' --content-view '$ccv' --from-lifecycle-environment '$prior' --to-lifecycle-environment '$lce'"

                prior=$lce
            done
            ;;
        esac
    done
fi


if ! $skip_push_to_capsules_setup ; then
    section 'Push content to capsules'
    ap 50-capsules-sync.log \
      -e "organization='{{ sat_org }}'" \
      -e "lces='$lces'" \
      -e "download_policy='${capsule_download_policy}'" \
      playbooks/tests/capsules-sync.yaml
    e CapusuleSync "$logs/50-capsules-sync.log"
fi


section 'Prepare for registrations'
unset aks
for rel in $rels; do
    for lce in $lces; do
        ak="AK_${rel}_${lce}"
        aks+="$ak "
    done
done

ap 60-generate-host-registration-commands.log \
  -e "organization='{{ sat_org }}'" \
  -e "aks='$aks'" \
  -e "sat_version='$sat_version'" \
  playbooks/satellite/host-registration_generate-commands.yaml

ap 61-recreate-client-scripts.log \
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

    registration_log="$prefix-${concurrent_registrations}.log"
    registration_profile_img="$prefix-${concurrent_registrations}.svg"

    log "Trying to register $concurrent_registrations content hosts concurrently in this batch"

    ap $registration_log \
      -e "size='$concurrent_registrations_per_container_host'" \
      -e "concurrent_registrations='$concurrent_registrations'" \
      -e "num_retry_forks='$num_retry_forks'" \
      -e "registration_logs='../../$logs/$prefix-container-host-client-logs'" \
      -e 're_register_failed_hosts=true' \
      -e "sat_version='$sat_version'" \
      -e "profile='$profile'" \
      -e "registration_profile_img='$registration_profile_img'" \
      playbooks/tests/registrations.yaml
    e Register $logs/$registration_log
done
grep Register "$logs"/$prefix-*.log >"$logs/$prefix-overall.log"
e Register "$logs/$prefix-overall.log"


section 'Sosreport'
skip_measurement='true' ap sosreporter-gatherer.log \
  -e "sosreport_gatherer_local_dir='../../$logs/sosreport/'" \
  playbooks/satellite/sosreport_gatherer.yaml


junit_upload
