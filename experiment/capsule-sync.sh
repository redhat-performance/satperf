#!/bin/bash

source experiment/run-library.sh

organization="${PARAM_organization:-Default Organization}"
manifest="${PARAM_manifest:-conf/contperf/manifest_SCA.zip}"
inventory="${PARAM_inventory:-conf/contperf/inventory.ini}"

cdn_url_full="${PARAM_cdn_url_full:-https://cdn.redhat.com/}"

rels='rhel6 rhel7 rhel8 rhel9'
basearch='x86_64'

sat_client_product='Satellite Client'

repo_sat_client_6="${PARAM_repo_sat_client_6:-http://mirror.example.com/Satellite_Client_6_x86_64/}"
repo_sat_client_7="${PARAM_repo_sat_client_7:-http://mirror.example.com/Satellite_Client_7_x86_64/}"
repo_sat_client_8="${PARAM_repo_sat_client_8:-http://mirror.example.com/Satellite_Client_8_x86_64/}"
repo_sat_client_9="${PARAM_repo_sat_client_9:-http://mirror.example.com/Satellite_Client_9_x86_64/}"

lces="${PARAM_lces:-Test QA Pre Prod}"

initial_index="${PARAM_initial_index:-0}"

dl='Default Location'

opts="--forks 100 -i $inventory"
opts_adhoc="$opts"


section "Checking environment"
generic_environment_check


section "Upload manifest"
h_out "--no-headers --csv organization list --fields name" | grep --quiet "^$organization$" \
  || h capsync-10-ensure-org.log "organization create --name '$organization'"
h_out "--no-headers --csv location list --fields name" | grep --quiet '^$dl$' \
  || h capsync-10-ensure-loc-in-org.log "organization add-location --name '$organization' --location '$dl'"
a capsync-10-manifest-deploy.log \
  -m copy \
  -a "src=$manifest dest=/root/manifest-auto.zip force=yes" satellite6
h capsync-10-manifest-upload.log "subscription upload --file '/root/manifest-auto.zip' --organization '$organization'"


section "Get OS content"
if [[ "$cdn_url_full" != 'https://cdn.redhat.com/' ]]; then
    h capsync-20-set-cdn-stage.log "organization update --name '$organization' --redhat-repository-url '$cdn_url_full'"
fi
h capsync-21-manifest-refresh.log "subscription refresh-manifest --organization '$organization'"

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
            os_product='Red Hat Enterprise Linux for x86_64'
            os_releasever='8'
            os_reposet_name="Red Hat Enterprise Linux 8 for $basearch - BaseOS (RPMs)"
            os_repo_name="Red Hat Enterprise Linux 8 for $basearch - BaseOS RPMs $os_releasever"
            os_appstream_reposet_name="Red Hat Enterprise Linux 8 for $basearch - AppStream (RPMs)"
            os_appstream_repo_name="Red Hat Enterprise Linux 8 for $basearch - AppStream RPMs $os_releasever"
            ;;
        rhel9)
            os_product='Red Hat Enterprise Linux for x86_64'
            os_releasever='9'
            os_reposet_name="Red Hat Enterprise Linux 9 for $basearch - BaseOS (RPMs)"
            os_repo_name="Red Hat Enterprise Linux 9 for $basearch - BaseOS RPMs $os_releasever"
            os_appstream_reposet_name="Red Hat Enterprise Linux 9 for $basearch - AppStream (RPMs)"
            os_appstream_repo_name="Red Hat Enterprise Linux 9 for $basearch - AppStream RPMs $os_releasever"
            ;;
    esac

    case $rel in
        rhel6)
            h capsync-25-reposet-enable-${rel}.log "repository-set enable --organization '$organization' --product '$os_product' --name '$os_reposet_name' --releasever '$os_releasever' --basearch '$basearch'"
            h capsync-26-repo-sync-${rel}.log "repository synchronize --organization '$organization' --product '$os_product' --name '$os_repo_name'"
            ;;
        rhel7)
            h capsync-25-reposet-enable-${rel}.log "repository-set enable --organization '$organization' --product '$os_product' --name '$os_reposet_name' --releasever '$os_releasever' --basearch '$basearch'"
            h capsync-26-repo-sync-${rel}.log "repository synchronize --organization '$organization' --product '$os_product' --name '$os_repo_name'"

            h capsync-25-reposet-enable-${rel}-extras.log "repository-set enable --organization '$organization' --product '$os_product' --name '$os_extras_reposet_name' --releasever '$os_releasever' --basearch '$basearch'"
            h capsync-26-repo-sync-${rel}-extras.log "repository synchronize --organization '$organization' --product '$os_product' --name '$os_extras_repo_name'"
            ;;
        rhel8|rhel9)
            h capsync-25-reposet-enable-${rel}-baseos.log "repository-set enable --organization '$organization' --product '$os_product' --name '$os_reposet_name' --releasever '$os_releasever' --basearch '$basearch'"
            h capsync-26-repo-sync-${rel}-baseos.log "repository synchronize --organization '$organization' --product '$os_product' --name '$os_repo_name'"

            h capsync-25-reposet-enable-${rel}-appstream.log "repository-set enable --organization '$organization' --product '$os_product' --name '$os_appstream_reposet_name' --releasever '$os_releasever' --basearch '$basearch'"
            h capsync-26-repo-sync-${rel}-appstream.log "repository synchronize --organization '$organization' --product '$os_product' --name '$os_appstream_repo_name'"
            ;;
    esac
done


section "Get Satellite Client content"
h capsync-27-product-create-sat-client.log "product create --organization '$organization' --name '$sat_client_product'"

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

    h capsync-28-repository-create-${rel}-sat-client.log "repository create --organization '$organization' --product '$sat_client_product' --name '$sat_client_repo_name' --content-type yum --url '$sat_client_repo_url'"
    h capsync-29-repository-sync-${rel}-sat-client.log "repository synchronize --organization '$organization' --product '$sat_client_product' --name '$sat_client_repo_name'"
done


section "Create LCE(s)"
prior='Library'
for lce in $lces; do
    h capsync-30-lce-create-${lce}.log "lifecycle-environment create --organization '$organization' --prior '$prior' --name '$lce'"
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
            os_repo_name="Red Hat Enterprise Linux 6 Server RPMs $basearch $os_releasever"
            os_rids="$( get_repo_id "$os_product" "$os_repo_name" )"
            sat_client_repo_name='Satellite Client for RHEL 6'
            sat_client_rids="$( get_repo_id "$sat_client_product" "$sat_client_repo_name" )"
            ;;
        rhel7)
            os_product='Red Hat Enterprise Linux Server'
            os_releasever='7Server'
            os_repo_name="Red Hat Enterprise Linux 7 Server RPMs $basearch $os_releasever"
            os_extras_repo_name="Red Hat Enterprise Linux 7 Server - Extras RPMs $basearch"
            os_rids="$( get_repo_id "$os_product" "$os_repo_name" )"
            os_rids=$os_rids,$( get_repo_id "$product" "$os_extras_repo_name" )
            sat_client_repo_name='Satellite Client for RHEL 7'
            sat_client_rids="$( get_repo_id "$sat_client_product" "$sat_client_repo_name" )"
            ;;
        rhel8)
            os_product='Red Hat Enterprise Linux for x86_64'
            os_releasever='8'
            os_repo_name="Red Hat Enterprise Linux 8 for $basearch - BaseOS RPMs $os_releasever"
            os_appstream_repo_name="Red Hat Enterprise Linux 8 for $basearch - AppStream RPMs $os_releasever"
            os_rids="$( get_repo_id "$os_product" "$os_repo_name" )"
            os_rids="$os_rids,$( get_repo_id "$os_product" "$os_appstream_repo_name" )"
            sat_client_repo_name='Satellite Client for RHEL 8'
            sat_client_rids="$( get_repo_id "$sat_client_product" "$sat_client_repo_name" )"
            ;;
        rhel9)
            os_product='Red Hat Enterprise Linux for x86_64'
            os_releasever='9'
            os_repo_name="Red Hat Enterprise Linux 9 for $basearch - BaseOS RPMs $os_releasever"
            os_appstream_repo_name="Red Hat Enterprise Linux 9 for $basearch - AppStream RPMs $os_releasever"
            os_rids="$( get_repo_id "$os_product" "$os_repo_name" )"
            os_rids="$os_rids,$( get_repo_id "$os_product" "$os_appstream_repo_name" )"
            sat_client_repo_name='Satellite Client for RHEL 9'
            sat_client_rids="$( get_repo_id "$sat_client_product" "$sat_client_repo_name" )"
            ;;
    esac

    # OS
    h capsync-31-cv-create-${rel}-os.log "content-view create --organization '$organization' --name '$cv_os' --repository-ids '$os_rids'"
    h capsync-32-cv-publish-${rel}-os.log "content-view publish --organization '$organization' --name '$cv_os'"

    # Satellite Client
    h capsync-33-cv-create-${rel}-sat-client.log "content-view create --organization '$organization' --name '$cv_sat_client' --repository-ids '$sat_client_rids'"
    h capsync-34-cv-publish-${rel}-sat-client.log "content-view publish --organization '$organization' --name '$cv_sat_client'"

    # CCV
    h capsync-35-ccv-create-${rel}.log "content-view create --organization '$organization' --composite --auto-publish yes --name '$ccv'"
    h capsync-36-ccv-component-add-${rel}.log "content-view component add --organization '$organization' --composite-content-view '$ccv' --component-content-view '$cv_os' --component-content-view '$cv_sat_client' --latest"
    h capsync-37-ccv-publish-${rel}.log "content-view publish --organization '$organization' --name '$ccv'"

    # Promotion to LCE(s)
    tmp="$( mktemp )"
    h_out "--no-headers --csv content-view version list --organization '$organization' --content-view '$ccv'" | grep '^[0-9]\+,' >$tmp
    version="$( head -n1 $tmp | cut -d ',' -f 3 | tr '\n' ',' | sed 's/,$//' )"
    rm -f $tmp
    prior='Library'
    for lce in $lces; do
        h capsync-38-ccv-promote-${rel}-${lce}.log "content-view version promote --organization '$organization' --content-view '$ccv' --version '$version' --from-lifecycle-environment '$prior' --to-lifecycle-environment '$lce'"
        prior="${lce}"
    done
done


section "Push content to capsules"
num_capsules="$(ansible -i $inventory --list-hosts capsules 2>/dev/null | grep -vc '^  hosts ')"

for (( iter=0, last=-1; last < (num_capsules - 1); iter++ )); do
    if (( initial_index == 0 && iter == 0 )); then
        continue
    else
        first="$(( last + 1 ))"
        incr="$(( initial_index + iter - 1 ))"
        last="$(( first + incr ))"
        if (( last >= num_capsules )); then
            last="$(( num_capsules - 1 ))"
        fi
        limit="${first}:${last}"
        num_concurrent_capsules="$(( last - first + 1 ))"
        ap capsync-40-populate-${iter}.log \
          --limit capsules["$limit"] \
          -e "organization='$organization'" \
          -e "lces='$lces'" \
          -e "num_concurrent_capsules='$num_concurrent_capsules'" \
          playbooks/satellite/capsules-populate.yaml
    fi
done


section "Sosreport"
skip_measurement='true' ap sosreporter-gatherer.log \
  -e "sosreport_gatherer_local_dir='../../$logs/sosreport/'" \
  playbooks/satellite/sosreport_gatherer.yaml


junit_upload
