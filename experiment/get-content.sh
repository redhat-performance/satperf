#!/bin/bash

source experiment/run-library.sh

branch="${PARAM_branch:-satcpt}"
inventory="${PARAM_inventory:-conf/contperf/inventory.${branch}.ini}"
manifest="${PARAM_manifest:-conf/contperf/manifest_SCA.zip}"

cdn_url_full="${PARAM_cdn_url_full:-https://cdn.redhat.com/}"

rels="${PARAM_rels:-rhel6 rhel7 rhel8 rhel9}"

lces="${PARAM_lces:-Test QA Pre Prod}"

basearch='x86_64'

sat_client_product='Satellite Client'

repo_sat_client_6="${PARAM_repo_sat_client_6:-http://mirror.example.com/Satellite_Client_6_x86_64/}"
repo_sat_client_7="${PARAM_repo_sat_client_7:-http://mirror.example.com/Satellite_Client_7_x86_64/}"
repo_sat_client_8="${PARAM_repo_sat_client_8:-http://mirror.example.com/Satellite_Client_8_x86_64/}"
repo_sat_client_9="${PARAM_repo_sat_client_9:-http://mirror.example.com/Satellite_Client_9_x86_64/}"

skip_down_setup="${PARAM_skip_down_setup:-false}"
satellite_download_policy="${PARAM_satellite_download_policy:-on_demand}"
skip_push_to_capsules_setup="${PARAM_skip_push_to_capsules_setup:-false}"
capsule_download_policy="${PARAM_capsule_download_policy:-inherit}"

dl='Default Location'

opts="--forks 100 -i $inventory"
opts_adhoc="$opts"


section "Checking environment"
generic_environment_check


if [[ "${skip_down_setup}" != "true" ]]; then
    section "Upload manifest"
    a 12-manifest-deploy.log \
      -m ansible.builtin.copy \
      -a "src=$manifest dest=/root/manifest-auto.zip force=yes" \
      satellite6
    h 15-manifest-upload.log "subscription upload --file '/root/manifest-auto.zip' --organization '{{ sat_org }}'"


    section "Get OS content"
    if [[ "${cdn_url_full}" != 'https://cdn.redhat.com/' ]]; then
        h 20-set-cdn-stage.log "organization update --name '{{ sat_org }}' --redhat-repository-url '${cdn_url_full}'"
    fi
    h 21-manifest-refresh.log "subscription refresh-manifest --organization '{{ sat_org }}'"

    if [[ "${satellite_download_policy}" != 'on_demand' ]]; then
        h 22-set-download-policy.log "settings set --organization '{{ sat_org }}' --name default_redhat_download_policy --value ${satellite_download_policy}"
    fi

    for rel in $rels; do
        case $rel in
            rhel6)
                os_product='Red Hat Enterprise Linux Server'
                os_releasever='6Server'
                os_reposet_name='Red Hat Enterprise Linux 6 Server (RPMs)'
                os_repo_name="Red Hat Enterprise Linux 6 Server RPMs $basearch ${os_releasever}"
                ;;
            rhel7)
                os_product='Red Hat Enterprise Linux Server'
                os_releasever='7Server'
                os_reposet_name='Red Hat Enterprise Linux 7 Server (RPMs)'
                os_repo_name="Red Hat Enterprise Linux 7 Server RPMs $basearch ${os_releasever}"
                os_extras_reposet_name='Red Hat Enterprise Linux 7 Server - Extras (RPMs)'
                os_extras_repo_name="Red Hat Enterprise Linux 7 Server - Extras RPMs $basearch"
                ;;
            rhel8)
                os_product='Red Hat Enterprise Linux for x86_64'
                os_releasever='8'
                os_reposet_name="Red Hat Enterprise Linux 8 for $basearch - BaseOS (RPMs)"
                os_repo_name="Red Hat Enterprise Linux 8 for $basearch - BaseOS RPMs ${os_releasever}"
                os_appstream_reposet_name="Red Hat Enterprise Linux 8 for $basearch - AppStream (RPMs)"
                os_appstream_repo_name="Red Hat Enterprise Linux 8 for $basearch - AppStream RPMs ${os_releasever}"
                ;;
            rhel9)
                os_product='Red Hat Enterprise Linux for x86_64'
                os_releasever='9'
                os_reposet_name="Red Hat Enterprise Linux 9 for $basearch - BaseOS (RPMs)"
                os_repo_name="Red Hat Enterprise Linux 9 for $basearch - BaseOS RPMs ${os_releasever}"
                os_appstream_reposet_name="Red Hat Enterprise Linux 9 for $basearch - AppStream (RPMs)"
                os_appstream_repo_name="Red Hat Enterprise Linux 9 for $basearch - AppStream RPMs ${os_releasever}"
                ;;
        esac

        case $rel in
            rhel6)
                h 25-reposet-enable-${rel}.log "repository-set enable --organization '{{ sat_org }}' --product '${os_product}' --name '${os_reposet_name}' --releasever '${os_releasever}' --basearch '$basearch'"
                h 26-repo-sync-${rel}.log "repository synchronize --organization '{{ sat_org }}' --product '${os_product}' --name '${os_repo_name}'"
                ;;
            rhel7)
                h 25-reposet-enable-${rel}.log "repository-set enable --organization '{{ sat_org }}' --product '${os_product}' --name '${os_reposet_name}' --releasever '${os_releasever}' --basearch '$basearch'"
                h 26-repo-sync-${rel}.log "repository synchronize --organization '{{ sat_org }}' --product '${os_product}' --name '${os_repo_name}'"

                h 25-reposet-enable-${rel}-extras.log "repository-set enable --organization '{{ sat_org }}' --product '${os_product}' --name '${os_extras_reposet_name}' --releasever '${os_releasever}' --basearch '$basearch'"
                h 26-repo-sync-${rel}-extras.log "repository synchronize --organization '{{ sat_org }}' --product '${os_product}' --name '${os_extras_repo_name}'"
                ;;
            rhel8|rhel9)
                h 25-reposet-enable-${rel}-baseos.log "repository-set enable --organization '{{ sat_org }}' --product '${os_product}' --name '${os_reposet_name}' --releasever '${os_releasever}' --basearch '$basearch'"
                h 26-repo-sync-${rel}-baseos.log "repository synchronize --organization '{{ sat_org }}' --product '${os_product}' --name '${os_repo_name}'"

                h 25-reposet-enable-${rel}-appstream.log "repository-set enable --organization '{{ sat_org }}' --product '${os_product}' --name '${os_appstream_reposet_name}' --releasever '${os_releasever}' --basearch '$basearch'"
                h 26-repo-sync-${rel}-appstream.log "repository synchronize --organization '{{ sat_org }}' --product '${os_product}' --name '${os_appstream_repo_name}'"
                ;;
        esac
    done


    section "Get Satellite Client content"
    # Satellite Client
    h 27-product-create-sat-client.log "product create --organization '{{ sat_org }}' --name '${sat_client_product}'"

    for rel in $rels; do
        case $rel in
            rhel6)
                sat_client_repo_name='Satellite Client for RHEL 6'
                sat_client_repo_url="${repo_sat_client_6}"
                ;;
            rhel7)
                sat_client_repo_name='Satellite Client for RHEL 7'
                sat_client_repo_url="${repo_sat_client_7}"
                ;;
            rhel8)
                sat_client_repo_name='Satellite Client for RHEL 8'
                sat_client_repo_url="${repo_sat_client_8}"
                ;;
            rhel9)
                sat_client_repo_name='Satellite Client for RHEL 9'
                sat_client_repo_url="${repo_sat_client_9}"
                ;;
        esac

        h 28-repository-create-${rel}-sat-client.log "repository create --organization '{{ sat_org }}' --product '${sat_client_product}' --name '${sat_client_repo_name}' --content-type yum --url '${sat_client_repo_url}'"
        h 29-repository-sync-${rel}-sat-client.log "repository synchronize --organization '{{ sat_org }}' --product '${sat_client_product}' --name '${sat_client_repo_name}'"
    done


    section "Create LCE(s)"
    prior='Library'
    for lce in $lces; do
        h 30-lce-create-${lce}.log "lifecycle-environment create --organization '{{ sat_org }}' --prior '$prior' --name '$lce'"
        prior="${lce}"
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
                os_repo_name="Red Hat Enterprise Linux 6 Server RPMs $basearch ${os_releasever}"
                os_rids="$( get_repo_id '{{ sat_org }}' "${os_product}" "${os_repo_name}" )"
                sat_client_repo_name='Satellite Client for RHEL 6'
                sat_client_rids="$( get_repo_id '{{ sat_org }}' "${sat_client_product}" "${sat_client_repo_name}" )"
                ;;
            rhel7)
                os_product='Red Hat Enterprise Linux Server'
                os_releasever='7Server'
                os_repo_name="Red Hat Enterprise Linux 7 Server RPMs $basearch ${os_releasever}"
                os_extras_repo_name="Red Hat Enterprise Linux 7 Server - Extras RPMs $basearch"
                os_rids="$( get_repo_id '{{ sat_org }}' "${os_product}" "${os_repo_name}" )"
                os_rids="${os_rids},$( get_repo_id '{{ sat_org }}' "${os_product}" "${os_extras_repo_name}" )"
                sat_client_repo_name='Satellite Client for RHEL 7'
                sat_client_rids="$( get_repo_id '{{ sat_org }}' "${sat_client_product}" "${sat_client_repo_name}" )"
                ;;
            rhel8)
                os_product='Red Hat Enterprise Linux for x86_64'
                os_releasever='8'
                os_repo_name="Red Hat Enterprise Linux 8 for $basearch - BaseOS RPMs ${os_releasever}"
                os_appstream_repo_name="Red Hat Enterprise Linux 8 for $basearch - AppStream RPMs ${os_releasever}"
                os_rids="$( get_repo_id '{{ sat_org }}' "${os_product}" "${os_repo_name}" )"
                os_rids="${os_rids},$( get_repo_id '{{ sat_org }}' "${os_product}" "${os_appstream_repo_name}" )"
                sat_client_repo_name='Satellite Client for RHEL 8'
                sat_client_rids="$( get_repo_id '{{ sat_org }}' "${sat_client_product}" "${sat_client_repo_name}" )"
                ;;
            rhel9)
                os_product='Red Hat Enterprise Linux for x86_64'
                os_releasever='9'
                os_repo_name="Red Hat Enterprise Linux 9 for $basearch - BaseOS RPMs ${os_releasever}"
                os_appstream_repo_name="Red Hat Enterprise Linux 9 for $basearch - AppStream RPMs ${os_releasever}"
                os_rids="$( get_repo_id '{{ sat_org }}' "${os_product}" "${os_repo_name}" )"
                os_rids="${os_rids},$( get_repo_id '{{ sat_org }}' "${os_product}" "${os_appstream_repo_name}" )"
                sat_client_repo_name='Satellite Client for RHEL 9'
                sat_client_rids="$( get_repo_id '{{ sat_org }}' "${sat_client_product}" "${sat_client_repo_name}" )"
                ;;
        esac
        content_label="$( h_out "--no-headers --csv repository list --organization '{{ sat_org }}' --search 'name = \"${sat_client_repo_name}\"' --fields 'Content label'" | tail -n1 )"

        # OS
        h 31-cv-create-${rel}-os.log "content-view create --organization '{{ sat_org }}' --name '${cv_os}' --repository-ids '${os_rids}'"
        h 32-cv-publish-${rel}-os.log "content-view publish --organization '{{ sat_org }}' --name '${cv_os}'"

        # Satellite Client
        h 33-cv-create-${rel}-sat-client.log "content-view create --organization '{{ sat_org }}' --name '${cv_sat_client}' --repository-ids '${sat_client_rids}'"
        h 34-cv-publish-${rel}-sat-client.log "content-view publish --organization '{{ sat_org }}' --name '${cv_sat_client}'"

        # CCV
        h 35-ccv-create-${rel}.log "content-view create --organization '{{ sat_org }}' --composite --auto-publish yes --name '$ccv'"

        h 36-ccv-component-add-${rel}-os.log "content-view component add --organization '{{ sat_org }}' --composite-content-view '$ccv' --component-content-view '${cv_os}' --latest"
        h 37-ccv-publish-${rel}-os.log "content-view publish --organization '{{ sat_org }}' --name '$ccv'"

        h 36-ccv-component-add-${rel}-sat-client.log "content-view component add --organization '{{ sat_org }}' --composite-content-view '$ccv' --component-content-view '${cv_sat_client}' --latest"
        h 37-ccv-publish-${rel}-sat-client.log "content-view publish --organization '{{ sat_org }}' --name '$ccv'"

        tmp="$( mktemp )"
        h_out "--no-headers --csv content-view version list --organization '{{ sat_org }}' --content-view '$ccv'" | grep '^[0-9]\+,' >$tmp
        version="$( head -n1 $tmp | cut -d ',' -f 3 | tr '\n' ',' | sed 's/,$//' )"
        rm -f $tmp

        prior='Library'
        for lce in $lces; do
            ak="AK_${rel}_${lce}"

            # CCV promotion to LCE
            h 38-ccv-promote-${rel}-${lce}.log "content-view version promote --organization '{{ sat_org }}' --content-view '$ccv' --version '$version' --from-lifecycle-environment '$prior' --to-lifecycle-environment '$lce'"

            # AK creation
            h 39-ak-create-${rel}-${lce}.log "activation-key create --content-view '$ccv' --lifecycle-environment '$lce' --name '$ak' --organization '{{ sat_org }}'"

            # Enable 'Satellite Client' repo in AK
            id="$( h_out "--no-headers --csv activation-key list --organization '{{ sat_org }}' --search 'name = \"$ak\"' --fields id"  | tail -n1 )"
            h 40-ak-content-override-${rel}-${lce}.log "activation-key content-override --organization '{{ sat_org }}' --id $id --content-label $content_label --override-name 'enabled' --value 1"

            prior="${lce}"
        done
    done
fi


if [[ "${skip_push_to_capsules_setup}" != "true" ]]; then
    section "Push content to capsules"
    ap 40-capsules-populate.log \
      -e "organization='{{ sat_org }}'" \
      -e "lces='$lces'" \
      -e "download_policy='${capsule_download_policy}'" \
      playbooks/satellite/capsules-populate.yaml
fi


section "Sosreport"
ap sosreporter-gatherer.log \
  -e "sosreport_gatherer_local_dir='../../$logs/sosreport/'" \
  playbooks/satellite/sosreport_gatherer.yaml


junit_upload
