#!/bin/sh

set -ex

function log() {
    echo "$( date --utc -Ins ) $@" | tee -a /root/create-big-setup-${ORG}.log >&2
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

hammer_logged settings set --name foreman_proxy_content_auto_sync --value false

for ORG in org1 org2 org3 org4 org5; do

hammer_logged organization create --name ${ORG} --locations "Location for gprfc031-vm1.usersys.redhat.com"
hammer_logged organization add-smart-proxy --name ${ORG} --smart-proxy gprfc031-vm1.usersys.redhat.com

hammer_logged subscription upload --organization ${ORG} --file ~/manifest_jhutar-2021-09-10-${ORG}_*.zip

hammer_logged lifecycle-environment create --name ${ORG}-le1 --prior Library --organization ${ORG}
hammer_logged lifecycle-environment create --name ${ORG}-le2 --prior ${ORG}-le1 --organization ${ORG}
hammer_logged lifecycle-environment create --name ${ORG}-le3 --prior ${ORG}-le2 --organization ${ORG}

hammer_logged capsule content add-lifecycle-environment --lifecycle-environment ${ORG}-le1 --name gprfc031-vm1.usersys.redhat.com --organization ${ORG}
hammer_logged capsule content add-lifecycle-environment --lifecycle-environment ${ORG}-le2 --name gprfc031-vm1.usersys.redhat.com --organization ${ORG}
hammer_logged capsule content add-lifecycle-environment --lifecycle-environment ${ORG}-le3 --name gprfc031-vm1.usersys.redhat.com --organization ${ORG}

hammer_logged repository-set enable --name 'Red Hat Ansible Engine 2.9 for RHEL 8 x86_64 (RPMs)' --basearch x86_64 --organization ${ORG}
hammer_logged repository-set enable --name 'Red Hat Ansible Engine 2.9 RPMs for Red Hat Enterprise Linux 7 Server' --basearch x86_64 --organization ${ORG}
hammer_logged repository-set enable --name 'Red Hat Enterprise Linux 7 Server (RPMs)' --basearch x86_64 --releasever 7Server --organization ${ORG}
hammer_logged repository-set enable --name 'Red Hat Enterprise Linux 8 for x86_64 - AppStream (RPMs)' --basearch x86_64 --releasever 8 --organization ${ORG}
hammer_logged repository-set enable --name 'Red Hat Enterprise Linux 8 for x86_64 - BaseOS (RPMs)' --basearch x86_64 --releasever 8 --organization ${ORG}
hammer_logged repository-set enable --name 'Red Hat Enterprise Linux 8 for x86_64 - Supplementary (RPMs)' --basearch x86_64 --releasever 8 --organization ${ORG}
hammer_logged repository-set enable --name 'Red Hat Satellite Tools 6.9 (for RHEL 7 Server) (RPMs)' --basearch x86_64 --organization ${ORG}
hammer_logged repository-set enable --name 'Red Hat Satellite Tools 6.9 for RHEL 8 x86_64 (RPMs)' --basearch x86_64 --organization ${ORG}
hammer_logged repository-set enable --name 'Red Hat Software Collections RPMs for Red Hat Enterprise Linux 7 Server' --basearch x86_64 --releasever 7Server --organization ${ORG}

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

hammer_logged content-view create --auto-publish false --name ${ORG}-cv-rhel7 --repository-ids "$rhel7" --organization ${ORG}
hammer_logged content-view create --auto-publish false --name ${ORG}-cv-rhel7_ansible --repository-ids "$rhel7_ansible" --organization ${ORG}
hammer_logged content-view create --auto-publish false --name ${ORG}-cv-rhel7_sattools --repository-ids "$rhel7_sattools" --organization ${ORG}
hammer_logged content-view create --auto-publish false --name ${ORG}-cv-rhel7_scl --repository-ids "$rhel7_scl" --organization ${ORG}
hammer_logged content-view create --auto-publish false --name ${ORG}-cv-rhel8_ansible --repository-ids "$rhel8_ansible" --organization ${ORG}
hammer_logged content-view create --auto-publish false --name ${ORG}-cv-rhel8_appstream --repository-ids "$rhel8_appstream" --organization ${ORG}
hammer_logged content-view create --auto-publish false --name ${ORG}-cv-rhel8_baseos --repository-ids "$rhel8_baseos" --organization ${ORG}
hammer_logged content-view create --auto-publish false --name ${ORG}-cv-rhel8_sattools --repository-ids "$rhel8_sattools" --organization ${ORG}
hammer_logged content-view create --auto-publish false --name ${ORG}-cv-rhel8_supp --repository-ids "$rhel8_supp" --organization ${ORG}

hammer_logged content-view create --auto-publish false --name ${ORG}-ccv-rhel7-min --composite --organization ${ORG}
hammer_logged content-view component add --composite-content-view ${ORG}-ccv-rhel7-min --component-content-view ${ORG}-cv-rhel7 --organization ${ORG} --latest
hammer_logged content-view component add --composite-content-view ${ORG}-ccv-rhel7-min --component-content-view ${ORG}-cv-rhel7_sattools --organization ${ORG} --latest

hammer_logged content-view create --auto-publish false --name ${ORG}-ccv-rhel7-max --composite --organization ${ORG}
hammer_logged content-view component add --composite-content-view ${ORG}-ccv-rhel7-max --component-content-view ${ORG}-cv-rhel7 --organization ${ORG} --latest
hammer_logged content-view component add --composite-content-view ${ORG}-ccv-rhel7-max --component-content-view ${ORG}-cv-rhel7_sattools --organization ${ORG} --latest
hammer_logged content-view component add --composite-content-view ${ORG}-ccv-rhel7-max --component-content-view ${ORG}-cv-rhel7_ansible --organization ${ORG} --latest
hammer_logged content-view component add --composite-content-view ${ORG}-ccv-rhel7-max --component-content-view ${ORG}-cv-rhel7_scl --organization ${ORG} --latest

hammer_logged content-view create --auto-publish false --name ${ORG}-ccv-rhel8-min --composite --organization ${ORG}
hammer_logged content-view component add --composite-content-view ${ORG}-ccv-rhel8-min --component-content-view ${ORG}-cv-rhel8_baseos --organization ${ORG} --latest
hammer_logged content-view component add --composite-content-view ${ORG}-ccv-rhel8-min --component-content-view ${ORG}-cv-rhel8_appstream --organization ${ORG} --latest
hammer_logged content-view component add --composite-content-view ${ORG}-ccv-rhel8-min --component-content-view ${ORG}-cv-rhel8_sattools --organization ${ORG} --latest

hammer_logged content-view create --auto-publish false --name ${ORG}-ccv-rhel8-max --composite --organization ${ORG}
hammer_logged content-view component add --composite-content-view ${ORG}-ccv-rhel8-max --component-content-view ${ORG}-cv-rhel8_baseos --organization ${ORG} --latest
hammer_logged content-view component add --composite-content-view ${ORG}-ccv-rhel8-max --component-content-view ${ORG}-cv-rhel8_appstream --organization ${ORG} --latest
hammer_logged content-view component add --composite-content-view ${ORG}-ccv-rhel8-max --component-content-view ${ORG}-cv-rhel8_sattools --organization ${ORG} --latest
hammer_logged content-view component add --composite-content-view ${ORG}-ccv-rhel8-max --component-content-view ${ORG}-cv-rhel8_ansible --organization ${ORG} --latest
hammer_logged content-view component add --composite-content-view ${ORG}-ccv-rhel8-max --component-content-view ${ORG}-cv-rhel8_supp --organization ${ORG} --latest

for cv in ${ORG}-cv-rhel7 ${ORG}-cv-rhel7_ansible ${ORG}-cv-rhel7_sattools ${ORG}-cv-rhel7_scl ${ORG}-cv-rhel8_ansible ${ORG}-cv-rhel8_appstream ${ORG}-cv-rhel8_baseos ${ORG}-cv-rhel8_sattools ${ORG}-cv-rhel8_supp; do
    hammer_logged content-view publish --name $cv --organization ${ORG} &
done
wait

for ccv in ${ORG}-ccv-rhel7-min ${ORG}-ccv-rhel7-max ${ORG}-ccv-rhel8-min ${ORG}-ccv-rhel8-max; do
    hammer_logged content-view publish --name $ccv --organization ${ORG} &
done
wait

for from_to in "Library ${ORG}-le1"; do
    from=$( echo "$from_to" | cut -d ' ' -f 1 )
    to=$( echo "$from_to" | cut -d ' ' -f 2 )
    for ccv in ${ORG}-ccv-rhel7-min ${ORG}-ccv-rhel7-max ${ORG}-ccv-rhel8-min ${ORG}-ccv-rhel8-max; do
        hammer_logged content-view version promote --content-view $ccv --from-lifecycle-environment $from --to-lifecycle-environment $to --organization ${ORG} &
    done
    wait
done

# Do not sync Smart Proxies after Content View promotion
hammer_logged settings set --name foreman_proxy_content_auto_sync --value false

done
