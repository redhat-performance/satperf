#!/bin/bash

source experiment/run-library.sh

rels="${PARAM_rels:-rhel7 rhel8 rhel9 rhel10}"
filter_cv="${PARAM_filter_cv:-false}"
filter_cv_rule_end_date="${PARAM_filter_cv_rule_end_date:-2024-09-01}"
filter_cv_rule_types="${PARAM_filter_cv_rule_types:-bugfix,security}"

# lces="${PARAM_lces:-Dev QA Pre Prod}"
lces="${PARAM_lces:-Test QA Pre Prod}"

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


section 'Checking environment'
generic_environment_check false false
# set +e

# Initial version sanity check
for rel in $rels; do
    case "$rel" in
    rhel[7-9]|rhel10)
        continue
        ;;
    *)
        echo "Wrong release: $rel!!!" && exit
        ;;
    esac
done

export skip_measurement=true

if ! $skip_down_setup; then
    section 'Upload manifest'
    a 01-manifest-deploy.log \
      -m ansible.builtin.copy \
      -a "src=$manifest dest=/root/manifest-auto.zip force=true" \
      satellite6
    h 01-manifest-upload.log \
      "subscription upload --file '/root/manifest-auto.zip' --organization '{{ sat_org }}'"
    h 01-manifest-refresh.log \
      "subscription refresh-manifest --organization '{{ sat_org }}'"


    section 'Sync OS from CDN'
    for rel in $rels; do
        case $rel in
            rhel6|rhel7)
                os_rel="${rel##rhel}"
                os_product='Red Hat Enterprise Linux Server'
                os_releasever="${os_rel}Server"
                os_repo_name="Red Hat Enterprise Linux $os_rel Server RPMs $basearch $os_releasever"
                os_reposet_name="Red Hat Enterprise Linux $os_rel Server (RPMs)"
                if [[ "$rel" == 'rhel7' ]]; then
                    os_extras_repo_name="Red Hat Enterprise Linux $os_rel Server - Extras RPMs $basearch"
                    os_extras_reposet_name="Red Hat Enterprise Linux $os_rel Server - Extras (RPMs)"
                fi
                ;;
            rhel8|rhel9|rhel10)
                os_rel="${rel##rhel}"
                os_product="Red Hat Enterprise Linux for $basearch"
                os_releasever=$os_rel
                os_repo_name="Red Hat Enterprise Linux $os_rel for $basearch - BaseOS RPMs $os_releasever"
                os_reposet_name="Red Hat Enterprise Linux $os_rel for $basearch - BaseOS (RPMs)"
                os_appstream_repo_name="Red Hat Enterprise Linux $os_rel for $basearch - AppStream RPMs $os_releasever"
                os_appstream_reposet_name="Red Hat Enterprise Linux $os_rel for $basearch - AppStream (RPMs)"
                ;;
        esac

        case $rel in
            rhel6|rhel7)
                h "05-reposet-enable-${rel}.log" \
                  "repository-set enable --organization '{{ sat_org }}' --product '$os_product' --name '$os_reposet_name' --releasever '$os_releasever' --basearch '$basearch'"
                h "06-repo-sync-${rel}.log" \
                  "repository synchronize --organization '{{ sat_org }}' --product '$os_product' --name '$os_repo_name'"

                if [[ "$rel" == 'rhel7' ]]; then
                    h "05-reposet-enable-${rel}extras.log" \
                      "repository-set enable --organization '{{ sat_org }}' --product '$os_product' --name '$os_extras_reposet_name' --releasever '$os_releasever' --basearch '$basearch'"
                    h "06-repo-sync-${rel}extras.log" \
                      "repository synchronize --organization '{{ sat_org }}' --product '$os_product' --name '$os_extras_repo_name'"
                fi
                ;;
            rhel8|rhel9|rhel10)
                h "05-reposet-enable-${rel}baseos.log" \
                  "repository-set enable --organization '{{ sat_org }}' --product '$os_product' --name '$os_reposet_name' --releasever '$os_releasever' --basearch '$basearch'"
                h "06-repo-sync-${rel}baseos.log" \
                  "repository synchronize --organization '{{ sat_org }}' --product '$os_product' --name '$os_repo_name'"

                h "05-reposet-enable-${rel}appstream.log" \
                  "repository-set enable --organization '{{ sat_org }}' --product '$os_product' --name '$os_appstream_reposet_name' --releasever '$os_releasever' --basearch '$basearch'"
                h "06-repo-sync-${rel}appstream.log" \
                  "repository synchronize --organization '{{ sat_org }}' --product '$os_product' --name '$os_appstream_repo_name'"
                ;;
        esac
    done


    section 'Create base LCE(s), CCV(s) and AK(s)'
    # LCE creation
    prior=Library
    for lce in $lces; do
        h "11-lce-create-${lce}.log" \
          "lifecycle-environment create --organization '{{ sat_org }}' --name '$lce' --prior '$prior'"

        prior=$lce
    done

    # CCV creation
    for rel in $rels; do
        ccv="CCV_$rel"

        h "12-ccv-create-${rel}.log" \
          "content-view create --organization '{{ sat_org }}' --name '$ccv' --composite --auto-publish yes"
        h "12-ccv-publish-${rel}.log" \
          "content-view publish --organization '{{ sat_org }}' --name '$ccv'"

        # CCV promotion to LCE(s)
        prior=Library
        for lce in $lces; do
            h "12-ccv-promote-${rel}-${lce}.log" \
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

            h "13-ak-create-${rel}-${lce}.log" \
              "activation-key create --organization '{{ sat_org }}' --name '$ak' --content-view '$ccv' --lifecycle-environment '$lce'"

            prior=$lce
        done
    done


    section 'Create, publish and promote OS CVs / CCVs to LCE(s)s'
    for rel in $rels; do
        ccv="CCV_$rel"

        case $rel in
            rhel6|rhel7)
                os_rel="${rel##rhel}"
                os_product='Red Hat Enterprise Linux Server'
                os_releasever="${os_rel}Server"
                os_repo_name="Red Hat Enterprise Linux $os_rel Server RPMs $basearch $os_releasever"
                os_rids="$( get_repo_id '{{ sat_org }}' "$os_product" "$os_repo_name" )"
                if [[ "$rel" == 'rhel7' ]]; then
                    os_extras_repo_name="Red Hat Enterprise Linux $os_rel Server - Extras RPMs $basearch"
                    os_rids="$os_rids,$( get_repo_id '{{ sat_org }}' "$os_product" "$os_extras_repo_name" )"
                fi
                ;;
            rhel8|rhel9|rhel10)
                os_rel="${rel##rhel}"
                os_product="Red Hat Enterprise Linux for $basearch"
                os_releasever=$os_rel
                os_repo_name="Red Hat Enterprise Linux $os_rel for $basearch - BaseOS RPMs $os_releasever"
                os_appstream_repo_name="Red Hat Enterprise Linux $os_rel for $basearch - AppStream RPMs $os_releasever"
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

        # Filtered OS CV
        cv_os_filtered="CV_${rel}_Filtered"
        filter_cv_os_filtered=Erratum_Inclusive

        h "15-cv-create-${rel}-os-filtered.log" \
          "content-view create --organization '{{ sat_org }}' --name '$cv_os_filtered' --repository-ids '$os_rids'"

        h "15-cv-filter-create-${rel}-os-filtered.log" \
          "content-view filter create --organization '{{ sat_org }}' --content-view '$cv_os_filtered' --name '$filter_cv_os_filtered' --type erratum --inclusion true"
        h "15-cv-filter-rule-create-${rel}-os-filtered.log" \
          "content-view filter rule create --organization '{{ sat_org }}' --content-view '$cv_os_filtered' --content-view-filter '$filter_cv_os_filtered' --date-type 'updated' --end-date '$filter_cv_rule_end_date' --types '$filter_cv_rule_types'"

        # CCV with OS
        if ! $filter_cv; then
            h "16-ccv-component-add-${rel}-os.log" \
              "content-view component add --organization '{{ sat_org }}' --composite-content-view '$ccv' --component-content-view '$cv_os' --latest"
        else
            h "16-ccv-component-add-${rel}-os-filtered.log" \
              "content-view component add --organization '{{ sat_org }}' --composite-content-view '$ccv' --component-content-view '$cv_os_filtered' --latest"
        fi

        h "15-cv-publish-${rel}-os-filtered.log" \
          "content-view publish --organization '{{ sat_org }}' --name '$cv_os_filtered'"

        h "16-ccv-publish-${rel}-os.log" \
          "content-view publish --organization '{{ sat_org }}' --name '$ccv'"

        # CCV promotion to LCE(s)
        prior=Library
        for lce in $lces; do
            h "16-ccv-promote-${rel}-os-${lce}.log" "content-view version promote --organization '{{ sat_org }}' --content-view '$ccv' --from-lifecycle-environment '$prior' --to-lifecycle-environment '$lce'"

            prior=$lce
        done
    done

    section 'Get Satellite Client content'
    # Satellite Client
    h 30-sat-client-product-create.log \
      "product create --organization '{{ sat_org }}' --name '$sat_client_product'"

    for rel in $rels; do
        ccv="CCV_${rel}"

        case $rel in
            rhel6|rhel7|rhel8|rhel9|rhel10)
                os_rel="${rel##rhel}"
                ;;
        esac
        sat_client_repo_name="Satellite Client for RHEL $os_rel"
        sat_client_repo_url="${repo_sat_client}/Satellite_Client_RHEL${os_rel}_${basearch}/"

        h "32-repository-create-sat-client_${rel}.log" \
          "repository create --organization '{{ sat_org }}' --product '$sat_client_product' --name '$sat_client_repo_name' --content-type yum --url '$sat_client_repo_url'"
        h "33-repository-sync-sat-client_${rel}.log" \
          "repository synchronize --organization '{{ sat_org }}' --product '$sat_client_product' --name '$sat_client_repo_name'" &

        sat_client_rids="$( get_repo_id '{{ sat_org }}' "$sat_client_product" "$sat_client_repo_name" )"
        content_label="$( h_out "--no-headers --csv repository list --organization '{{ sat_org }}' --search 'name = \"$sat_client_repo_name\"' --fields 'Content label'" | tail -n1 )"

        # Satellite Client CV
        cv_sat_client="CV_${rel}-sat-client"

        h "35-cv-create-${rel}-sat-client.log" \
          "content-view create --organization '{{ sat_org }}' --name '$cv_sat_client' --repository-ids '$sat_client_rids'"

        # XXX: Apparently, if we publish the repo "too early" (before it's finished sync'ing???), the version published won't have any content
        wait

         # CCV with Satellite Client
        h "36-ccv-component-add-${rel}-sat-client.log" \
          "content-view component add --organization '{{ sat_org }}' --composite-content-view '$ccv' --component-content-view '$cv_sat_client' --latest"

        h "35-cv-publish-${rel}-sat-client.log" \
          "content-view publish --organization '{{ sat_org }}' --name '$cv_sat_client'"

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
    wait


    section 'Get RHOSP content'
    # RHOSP
    h 40-product-create-rhsop.log "product create --organization '{{ sat_org }}' --name '$rhosp_product'"

    for rel in $rels; do
        ccv="CCV_${rel}"

        case $rel in
            rhel8|rhel9|rhel10)
                rhsop_repo_name="rhosp-${rel}/openstack-base"

                h "42-repository-create-rhosp-${rel}_openstack-base.log" \
                  "repository create --organization '{{ sat_org }}' --product '$rhosp_product' --name '$rhsop_repo_name' --content-type docker --url '$rhosp_registry_url' --docker-upstream-name '$rhsop_repo_name' --upstream-username '$rhosp_registry_username' --upstream-password '$rhosp_registry_password'"
                h "43-repository-sync-rhosp-${rel}_openstack-base.log" \
                  "repository synchronize --organization '{{ sat_org }}' --product '$rhosp_product' --name '$rhsop_repo_name'" &

                rhosp_rids="$( get_repo_id '{{ sat_org }}' "$rhosp_product" "$rhsop_repo_name" )"
                content_label="$( h_out "--no-headers --csv repository list --organization '{{ sat_org }}' --search 'name = \"$rhosp_rids\"' --fields 'Content label'" | tail -n1 )"

                # RHOSP CV
                cv_osp="CV_${rel}-osp"

                h "45-cv-create-rhosp-${rel}.log" \
                  "content-view create --organization '{{ sat_org }}' --name '$cv_osp' --repository-ids '$rhosp_rids'"

                # XXX: Apparently, if we publish the repo "too early" (before it's finished sync'ing???), the version published won't have any content
                wait

                # CCV with RHOSP
                h "46-ccv-component-add-rhosp-${rel}.log" \
                  "content-view component add --organization '{{ sat_org }}' --composite-content-view '$ccv' --component-content-view '$cv_osp' --latest"

                h "45-cv-publish-rhosp-${rel}.log" \
                  "content-view publish --organization '{{ sat_org }}' --name '$cv_osp'"

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


section 'Sosreport'
ap sosreporter-gatherer.log \
  -e "sosreport_gatherer_local_dir='../../$logs/sosreport/'" \
  playbooks/satellite/sosreport_gatherer.yaml


junit_upload
