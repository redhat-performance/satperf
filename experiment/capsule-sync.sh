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

initial_index="${PARAM_initial_index:-0}"

dl='Default Location'

opts="--forks 100 -i $inventory"
opts_adhoc="$opts -e branch='$branch'"


section "Checking environment"
generic_environment_check


section "Upload manifest"
h_out "--no-headers --csv organization list --search 'name = \"{{ sat_org }}\"'" | grep --quiet '^[0-9]\+,' \
  || h 10-ensure-org.log "organization create --name '{{ sat_org }}'"

h_out "--no-headers --csv location list --search 'name = \"$dl\"' --fields name" | grep --quiet "^$dl$" \
  || h 11-ensure-loc-in-org.log "organization add-location --name '{{ sat_org }}' --location '$dl'"

a 12-manifest-deploy.log \
  -m ansible.builtin.copy \
  -a "src=$manifest dest=/root/manifest-auto.zip force=yes" \
  satellite6
h 15-manifest-upload.log "subscription upload --file '/root/manifest-auto.zip' --organization '{{ sat_org }}'"


section "Get OS content"
if [[ "$cdn_url_full" != 'https://cdn.redhat.com/' ]]; then
    h 20-set-cdn-stage.log "organization update --name '{{ sat_org }}' --redhat-repository-url '$cdn_url_full'"
fi
h 21-manifest-refresh.log "subscription refresh-manifest --organization '{{ sat_org }}'"

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
            h 25-reposet-enable-${rel}.log "repository-set enable --organization '{{ sat_org }}' --product '$os_product' --name '$os_reposet_name' --releasever '$os_releasever' --basearch '$basearch'"
            h 26-repo-sync-${rel}.log "repository synchronize --organization '{{ sat_org }}' --product '$os_product' --name '$os_repo_name'"
            ;;
        rhel7)
            h 25-reposet-enable-${rel}.log "repository-set enable --organization '{{ sat_org }}' --product '$os_product' --name '$os_reposet_name' --releasever '$os_releasever' --basearch '$basearch'"
            h 26-repo-sync-${rel}.log "repository synchronize --organization '{{ sat_org }}' --product '$os_product' --name '$os_repo_name'"

            h 25-reposet-enable-${rel}-extras.log "repository-set enable --organization '{{ sat_org }}' --product '$os_product' --name '$os_extras_reposet_name' --releasever '$os_releasever' --basearch '$basearch'"
            h 26-repo-sync-${rel}-extras.log "repository synchronize --organization '{{ sat_org }}' --product '$os_product' --name '$os_extras_repo_name'"
            ;;
        rhel8|rhel9)
            h 25-reposet-enable-${rel}-baseos.log "repository-set enable --organization '{{ sat_org }}' --product '$os_product' --name '$os_reposet_name' --releasever '$os_releasever' --basearch '$basearch'"
            h 26-repo-sync-${rel}-baseos.log "repository synchronize --organization '{{ sat_org }}' --product '$os_product' --name '$os_repo_name'"

            h 25-reposet-enable-${rel}-appstream.log "repository-set enable --organization '{{ sat_org }}' --product '$os_product' --name '$os_appstream_reposet_name' --releasever '$os_releasever' --basearch '$basearch'"
            h 26-repo-sync-${rel}-appstream.log "repository synchronize --organization '{{ sat_org }}' --product '$os_product' --name '$os_appstream_repo_name'"
            ;;
    esac
done


section "Get Satellite Client content"
# Satellite Client
h 27-product-create-sat-client.log "product create --organization '{{ sat_org }}' --name '$sat_client_product'"

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

    h 28-repository-create-${rel}-sat-client.log "repository create --organization '{{ sat_org }}' --product '$sat_client_product' --name '$sat_client_repo_name' --content-type yum --url '$sat_client_repo_url'"
    h 29-repository-sync-${rel}-sat-client.log "repository synchronize --organization '{{ sat_org }}' --product '$sat_client_product' --name '$sat_client_repo_name'"
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
            os_repo_name="Red Hat Enterprise Linux 6 Server RPMs $basearch $os_releasever"
            os_rids="$( get_repo_id '{{ sat_org }}' "$os_product" "$os_repo_name" )"
            sat_client_repo_name='Satellite Client for RHEL 6'
            sat_client_rids="$( get_repo_id '{{ sat_org }}' "$sat_client_product" "$sat_client_repo_name" )"
            ;;
        rhel7)
            os_product='Red Hat Enterprise Linux Server'
            os_releasever='7Server'
            os_repo_name="Red Hat Enterprise Linux 7 Server RPMs $basearch $os_releasever"
            os_extras_repo_name="Red Hat Enterprise Linux 7 Server - Extras RPMs $basearch"
            os_rids="$( get_repo_id '{{ sat_org }}' "$os_product" "$os_repo_name" )"
            os_rids="$os_rids,$( get_repo_id '{{ sat_org }}' "$os_product" "$os_extras_repo_name" )"
            sat_client_repo_name='Satellite Client for RHEL 7'
            sat_client_rids="$( get_repo_id '{{ sat_org }}' "$sat_client_product" "$sat_client_repo_name" )"
            ;;
        rhel8)
            os_product='Red Hat Enterprise Linux for x86_64'
            os_releasever='8'
            os_repo_name="Red Hat Enterprise Linux 8 for $basearch - BaseOS RPMs $os_releasever"
            os_appstream_repo_name="Red Hat Enterprise Linux 8 for $basearch - AppStream RPMs $os_releasever"
            os_rids="$( get_repo_id '{{ sat_org }}' "$os_product" "$os_repo_name" )"
            os_rids="$os_rids,$( get_repo_id '{{ sat_org }}' "$os_product" "$os_appstream_repo_name" )"
            sat_client_repo_name='Satellite Client for RHEL 8'
            sat_client_rids="$( get_repo_id '{{ sat_org }}' "$sat_client_product" "$sat_client_repo_name" )"
            ;;
        rhel9)
            os_product='Red Hat Enterprise Linux for x86_64'
            os_releasever='9'
            os_repo_name="Red Hat Enterprise Linux 9 for $basearch - BaseOS RPMs $os_releasever"
            os_appstream_repo_name="Red Hat Enterprise Linux 9 for $basearch - AppStream RPMs $os_releasever"
            os_rids="$( get_repo_id '{{ sat_org }}' "$os_product" "$os_repo_name" )"
            os_rids="$os_rids,$( get_repo_id '{{ sat_org }}' "$os_product" "$os_appstream_repo_name" )"
            sat_client_repo_name='Satellite Client for RHEL 9'
            sat_client_rids="$( get_repo_id '{{ sat_org }}' "$sat_client_product" "$sat_client_repo_name" )"
            ;;
    esac

    # OS
    h 31-cv-create-${rel}-os.log "content-view create --organization '{{ sat_org }}' --name '$cv_os' --repository-ids '$os_rids'"
    h 32-cv-publish-${rel}-os.log "content-view publish --organization '{{ sat_org }}' --name '$cv_os'"

    # Satellite Client
    h 33-cv-create-${rel}-sat-client.log "content-view create --organization '{{ sat_org }}' --name '$cv_sat_client' --repository-ids '$sat_client_rids'"
    h 34-cv-publish-${rel}-sat-client.log "content-view publish --organization '{{ sat_org }}' --name '$cv_sat_client'"

    # CCV
    h 35-ccv-create-${rel}.log "content-view create --organization '{{ sat_org }}' --composite --auto-publish yes --name '$ccv'"
    h 36-ccv-component-add-${rel}.log "content-view component add --organization '{{ sat_org }}' --composite-content-view '$ccv' --component-content-view '$cv_os' --component-content-view '$cv_sat_client' --latest"
    h 37-ccv-publish-${rel}.log "content-view publish --organization '{{ sat_org }}' --name '$ccv'"

    # Promotion to LCE(s)
    tmp="$( mktemp )"
    h_out "--no-headers --csv content-view version list --organization '{{ sat_org }}' --content-view '$ccv'" | grep '^[0-9]\+,' >$tmp
    version="$( head -n1 $tmp | cut -d ',' -f 3 | tr '\n' ',' | sed 's/,$//' )"
    rm -f $tmp

    prior='Library'
    for lce in $lces; do
        h 38-ccv-promote-${rel}-${lce}.log "content-view version promote --organization '{{ sat_org }}' --content-view '$ccv' --version '$version' --from-lifecycle-environment '$prior' --to-lifecycle-environment '$lce'"
        prior="${lce}"
    done
done


section "Push content to capsules"
num_capsules="$(ansible $opts_adhoc --list-hosts capsules 2>/dev/null | grep -vc '^  hosts ')"

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
          -e "organization='{{ sat_org }}'" \
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
