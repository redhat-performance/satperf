#!/bin/bash

source experiment/run-library.sh

organization="${PARAM_organization:-Default Organization}"
manifest="${PARAM_manifest:-conf/contperf/manifest_SCA.zip}"
inventory="${PARAM_inventory:-conf/contperf/inventory.ini}"
local_conf="${PARAM_local_conf:-conf/satperf.local.yaml}"

cdn_url_full="${PARAM_cdn_url_full:-https://cdn.redhat.com/}"

rels="${PARAM_rels:-rhel6 rhel7 rhel8 rhel9}"

lces="${PARAM_lces:-Test QA Pre Prod}"

basearch='x86_64'

sat_client_product='Satellite Client'

repo_sat_client_6="${PARAM_repo_sat_client_6:-http://mirror.example.com/Satellite_Client_6_x86_64/}"
repo_sat_client_7="${PARAM_repo_sat_client_7:-http://mirror.example.com/Satellite_Client_7_x86_64/}"
repo_sat_client_8="${PARAM_repo_sat_client_8:-http://mirror.example.com/Satellite_Client_8_x86_64/}"
repo_sat_client_9="${PARAM_repo_sat_client_9:-http://mirror.example.com/Satellite_Client_9_x86_64/}"

dl="Default Location"

opts="--forks 100 -i $inventory"
opts_adhoc="$opts -e @conf/satperf.yaml -e @$local_conf"

satellite_host="$( ansible $opts_adhoc --list-hosts satellite6 2>/dev/null | tail -n 1 | sed -e 's/^\s\+//' -e 's/\s\+$//' )"

section "Checking environment"
generic_environment_check


section "Upload manifest"
h_out "--no-headers --csv organization list --fields name" | grep --quiet "^$organization$" \
  || h 10-ensure-org.log "organization create --name '$organization'"
h_out "--no-headers --csv location list --name '$organization' --fields name" | grep --quiet '^$dl$' \
  || h 11-ensure-loc-in-org.log "organization add-location --name '$organization' --location '$dl'"
skip_measurement='true' a 12-manifest-deploy.log \
  -m ansible.builtin.copy \
  -a "src=$manifest dest=/root/manifest-auto.zip force=yes" satellite6
skip_measurement='true' h 15-manifest-upload.log "subscription upload --file '/root/manifest-auto.zip' --organization '$organization'"


export skip_measurement='true'
section "Get OS content"
if [[ "$cdn_url_full" != 'https://cdn.redhat.com/' ]]; then
    h 20-set-cdn-stage.log "organization update --name '$organization' --redhat-repository-url '$cdn_url_full'"
fi
h 21-manifest-refresh.log "subscription refresh-manifest --organization '$organization'"

sca_status="$(h_out "--no-headers --csv simple-content-access status --organization '$organization'" | grep -v "^$satellite_host \| ")"


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
            h 25-reposet-enable-${rel}.log "repository-set enable --organization '$organization' --product '$os_product' --name '$os_reposet_name' --releasever '$os_releasever' --basearch '$basearch'"
            h 26-repo-sync-${rel}.log "repository synchronize --organization '$organization' --product '$os_product' --name '$os_repo_name'"
            ;;
        rhel7)
            h 25-reposet-enable-${rel}.log "repository-set enable --organization '$organization' --product '$os_product' --name '$os_reposet_name' --releasever '$os_releasever' --basearch '$basearch'"
            h 26-repo-sync-${rel}.log "repository synchronize --organization '$organization' --product '$os_product' --name '$os_repo_name'"

            h 25-reposet-enable-${rel}-extras.log "repository-set enable --organization '$organization' --product '$os_product' --name '$os_extras_reposet_name' --releasever '$os_releasever' --basearch '$basearch'"
            h 26-repo-sync-${rel}-extras.log "repository synchronize --organization '$organization' --product '$os_product' --name '$os_extras_repo_name'"
            ;;
        rhel8|rhel9)
            h 25-reposet-enable-${rel}-baseos.log "repository-set enable --organization '$organization' --product '$os_product' --name '$os_reposet_name' --releasever '$os_releasever' --basearch '$basearch'"
            h 26-repo-sync-${rel}-baseos.log "repository synchronize --organization '$organization' --product '$os_product' --name '$os_repo_name'"

            h 25-reposet-enable-${rel}-appstream.log "repository-set enable --organization '$organization' --product '$os_product' --name '$os_appstream_reposet_name' --releasever '$os_releasever' --basearch '$basearch'"
            h 26-repo-sync-${rel}-appstream.log "repository synchronize --organization '$organization' --product '$os_product' --name '$os_appstream_repo_name'"
            ;;
    esac
done

section "Get Satellite Client content"
# Satellite Client
h 27-product-create-sat-client.log "product create --organization '$organization' --name '$sat_client_product'"

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

    h 28-repository-create-${rel}-sat-client.log "repository create --organization '$organization' --product '$sat_client_product' --name '$sat_client_repo_name' --content-type yum --url '$sat_client_repo_url'"
    h 29-repository-sync-${rel}-sat-client.log "repository synchronize --organization '$organization' --product '$sat_client_product' --name '$sat_client_repo_name'"
done
unset skip_measurement


section "Create LCE(s)"
prior='Library'
for lce in $lces; do
    h 30-lce-create-${lce}.log "lifecycle-environment create --organization '$organization' --prior '$prior' --name '$lce'"
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
            os_rids="$os_rids,$( get_repo_id "$product" "$os_extras_repo_name" )"
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
    h 31-cv-create-${rel}-os.log "content-view create --organization '$organization' --name '$cv_os' --repository-ids '$os_rids'"
    h 32-cv-publish-${rel}-os.log "content-view publish --organization '$organization' --name '$cv_os'"

    # Satellite Client
    h 33-cv-create-${rel}-sat-client.log "content-view create --organization '$organization' --name '$cv_sat_client' --repository-ids '$sat_client_rids'"
    h 34-cv-publish-${rel}-sat-client.log "content-view publish --organization '$organization' --name '$cv_sat_client'"

    # CCV
    h 35-ccv-create-${rel}.log "content-view create --organization '$organization' --composite --auto-publish yes --name '$ccv'"
    h 36-ccv-component-add-${rel}.log "content-view component add --organization '$organization' --composite-content-view '$ccv' --component-content-view '$cv_os' --component-content-view '$cv_sat_client' --latest"
    h 37-ccv-publish-${rel}.log "content-view publish --organization '$organization' --name '$ccv'"

    # Promotion to LCE(s)
    tmp="$( mktemp )"
    h_out "--no-headers --csv content-view version list --organization '$organization' --content-view '$ccv'" | grep '^[0-9]\+,' >$tmp
    version="$( head -n1 $tmp | cut -d ',' -f 3 | tr '\n' ',' | sed 's/,$//' )"
    rm -f $tmp
    prior='Library'
    for lce in $lces; do
        h 38-ccv-promote-${rel}-${lce}.log "content-view version promote --organization '$organization' --content-view '$ccv' --version '$version' --from-lifecycle-environment '$prior' --to-lifecycle-environment '$lce'"
        prior="${lce}"
    done
done


section "Push content to capsules"
ap 40-capsules-populate.log \
  -e "organization='$organization'" \
  -e "lces='$lces'" \
  playbooks/satellite/capsules-populate.yaml


export skip_measurement='true'
section "Prepare for registrations"

h_out "--no-headers --csv domain list --search 'name = {{ domain }}'" | grep --quiet '^[0-9]\+,' \
  || h 42-domain-create.log "domain create --name '{{ domain }}' --organizations '$organization'"

tmp="$( mktemp )"
h_out "--no-headers --csv location list --organization '$organization'" | grep '^[0-9]\+,' >$tmp
location_ids="$( cut -d ',' -f 1 $tmp | tr '\n' ',' | sed 's/,$//' )"
rm -f $tmp

h 42-domain-update.log "domain update --name '{{ domain }}' --organizations '$organization' --location-ids '$location_ids'"

for rel in $rels; do
    ccv="CCV_$rel"

    for lce in $lces; do
        ak="AK_${lce}_${rel}"
        echo $ak

        h 43-ak-create-$lce-$rel.log "activation-key create --content-view '$ccv' --lifecycle-environment '$lce' --name '$ak' --organization '$organization'"

        if [[ "$sca_status" != 'true' ]]; then
            h_out "--csv subscription list --organization '$organization' --search 'name = \"$rhel_subscription\"'" >$logs/subs-list-rhel-$lce-$rel.log
            rhel_subs_id="$( tail -n 1 $logs/subs-list-rhel-$lce-$rel.log | cut -d ',' -f 1 )"
            h 43-ak-add-subs-rhel-$lce-$rel.log "activation-key add-subscription --organization '$organization' --name '$ak' --subscription-id '$rhel_subs_id'"

            h_out "--csv subscription list --organization '$organization' --search 'name = \"$sat_client_product\"'" >$logs/subs-list-sat-client-$lce-$rel.log
            sat_client_subs_id="$( tail -n 1 $logs/subs-list-sat-client-$lce-$rel.log | cut -d ',' -f 1 )"
            h 43-ak-add-subs-sat-client-$lce-$rel.log "activation-key add-subscription --organization '$organization' --name '$ak' --subscription-id '$sat_client_subs_id'"
        fi
    done
done
