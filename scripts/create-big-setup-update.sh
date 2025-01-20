#!/bin/sh

set -ex

function log() {
    echo "$( date --utc -Ins ) $@" | tee -a /root/create-big-setup-update-${ORG}.log >&2
}

function hammer_logged() {
    local before=$( date +%s )
    hammer "$@"
    rc=$?
    local after=$( date +%s )
    log "DEBUG Command 'hammer $@' finished in $( expr $after - $before ) seconds with exit code $rc"
}

function get_id() {
    hammer --output csv --no-headers repository list --organization ${ORG} | grep "^[0-9]\+,$1," | cut -d ',' -f 1
}

for ORG in org1 org2 org3 org4 org5; do

rhel7=$( get_id "Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server" )
rhel7_ansible=$( get_id "Red Hat Ansible Engine 2.9 RPMs for Red Hat Enterprise Linux 7 Server x86_64" )
rhel7_sattools=$( get_id "Red Hat Satellite Tools 6.9 for RHEL 7 Server RPMs x86_64" )
rhel7_scl=$( get_id "Red Hat Software Collections RPMs for Red Hat Enterprise Linux 7 Server x86_64 7Server" )
rhel8_ansible=$( get_id "Red Hat Ansible Engine 2.9 for RHEL 8 x86_64 RPMs" )
rhel8_appstream=$( get_id "Red Hat Enterprise Linux 8 for x86_64 - AppStream RPMs 8" )
rhel8_baseos=$( get_id "Red Hat Enterprise Linux 8 for x86_64 - BaseOS RPMs 8" )
rhel8_sattools=$( get_id "Red Hat Satellite Tools 6.9 for RHEL 8 x86_64 RPMs" )
rhel8_supp=$( get_id "Red Hat Enterprise Linux 8 for x86_64 - Supplementary RPMs 8" )

for r in $rhel7 $rhel7_ansible $rhel7_sattools $rhel7_scl $rhel8_ansible $rhel8_appstream $rhel8_baseos $rhel8_sattools $rhel8_supp; do
    hammer_logged repository synchronize --id $r --organization ${ORG} &
done
wait

for cv in ${ORG}-cv-rhel7 ${ORG}-cv-rhel7_ansible ${ORG}-cv-rhel7_sattools ${ORG}-cv-rhel7_scl ${ORG}-cv-rhel8_ansible ${ORG}-cv-rhel8_appstream ${ORG}-cv-rhel8_baseos ${ORG}-cv-rhel8_sattools ${ORG}-cv-rhel8_supp; do
    rule_id=$( hammer --output csv --no-headers content-view filter rule list --organization ${ORG} --content-view-filter TIME --content-view $cv --fields "Rule ID" | head -n 1 )
    end_date=$( hammer --output csv --no-headers content-view filter rule info --organization ${ORG} --content-view-filter TIME --content-view $cv --id $rule_id --fields "End Date" )
    new_end_date=$( date -d "$end_date - 30 day" +"%Y-%m-%d" )
    hammer content-view filter rule update --organization ${ORG} --content-view-filter TIME --content-view $cv --id $rule_id --end-date $new_end_date
    hammer_logged content-view publish --name $cv --organization ${ORG} &
done
wait

for ccv in ${ORG}-ccv-rhel7-min ${ORG}-ccv-rhel7-max ${ORG}-ccv-rhel8-min ${ORG}-ccv-rhel8-max; do
    hammer_logged content-view publish --name $ccv --organization ${ORG}
done

for from_to in "${ORG}-le2 ${ORG}-le3" "${ORG}-le1 ${ORG}-le2" "Library ${ORG}-le1"; do
    from=$( echo "$from_to" | cut -d ' ' -f 1 )
    to=$( echo "$from_to" | cut -d ' ' -f 2 )
    for ccv in ${ORG}-ccv-rhel7-min ${ORG}-ccv-rhel7-max ${ORG}-ccv-rhel8-min ${ORG}-ccv-rhel8-max; do
        versions=$( hammer --output csv --no-headers content-view version list --content-view $ccv --lifecycle-environment $from --organization ${ORG} )
        if [[ ${#versions} -gt 0 ]]; then
            hammer_logged content-view version promote --content-view $ccv --from-lifecycle-environment $from --to-lifecycle-environment $to --organization ${ORG}
        else
            log "DEBUG: CCV $ccv version not in $from LE, skipping promote"
        fi
    done
done

done
