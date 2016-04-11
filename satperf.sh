#!/bin/bash

#Author Pradeep Kumar Surisetty<psuriset@redhat.com>

source satperf.cfg
tname=$2
testprefix=satelitte61-$tname


function satperf_usage() {
    printf "The following options are available:\n"
    printf "\n"
    printf -- "\t --help : Help options\n"
    printf -- "\t --install : Install satelitte from latest repo\n"
    printf -- "\t --sat-backup : Take satelitte server backup to restore further\n"
    printf -- "\t --sat-restore : Restore from backup\n"
    printf -- "\t --setup : Setup pbench and clear preregistered debug tools \n"
    printf -- "\t --upload : Upload manifest\n"
    printf -- "\t --add-product : Adding products\n"
    printf -- "\t --create-life-cycle : Create life cycle environments\n"
    printf -- "\t --enable-content : Enable repos\n"
    printf -- "\t --content-view-create : Create content view and add repos\n"
    printf -- "\t --content-view-publish : Publish content views\n"
    printf -- "\t --sync-content : Sync content (concurrent or sequential) from repo server to satelitte server\n"
    printf -- "\t --resync-content : Resync content (concurrent or sequential) from repo server to satelitte server\n"
    printf -- "\t --install-capsule : Install capsule on mentioned capsule nodes \n"
    printf -- "\t --sync-capsule :  Sync capsule (concurrent or sequential) \n"
    printf -- "\t --register-content-hosts :  Register content hosts (concurrent or sequential) \n"
    printf -- "\t --remove-capsule : Uninstall capsule\n"
    printf -- "\t --all : Run all jobs in sequence\n"
}


function log()
{
    echo "[$(date)]: $*"
}


function pbench_cleanup()
{
    log clearing prerigestered tools
    #cleanup tools if any
    clear-tools
    clear-results
    kill-tools
    #drop cache
    echo 3 > /proc/sys/vm/drop_caches
}


function pbench_config()
{
     if $PBENCH ; then
         pbench_cleanup
         log registering tools
         register-tool-set
         unregister-tool --name perf
     fi
}


function pbench_postprocess()
{
      log clearing tools
      kill-tools
      clear-tools
      #clear-results
      move-results
}


function upload_manifest()
{
    log Upload Manifest
    time hammer -u "${ADMIN_USER}" -p "${ADMIN_PASSWORD}" subscription upload --organization "${ORG}" --file $MANIFSET --repository-url $REPOSERVER
}


function add_products()
{
    log Add products
    for product in $PRODUCTS; do
        echo "[$(date -R)] Adding Product: ${product}"
        time hammer -u admin -p changeme product create --organization-id 1 --name ${product}
    done
}


function create_life_cycle_env()
{
    log create life cyccle environment
    time hammer -u "${ADMIN_USER}" -p "${ADMIN_PASSWORD}" lifecycle-environment create --name='DEV' --prior='Library' --organization="${ORG}"
    time hammer -u "${ADMIN_USER}" -p "${ADMIN_PASSWORD}" lifecycle-environment create --name='QE' --prior='DEV' --organization="${ORG}"
}


function enable_content()
{
    log Enable content
    log Enable RHEL 5 x86_64 content
    time hammer -u "${ADMIN_USER}" -p "${ADMIN_PASSWORD}" repository-set enable --name="Red Hat Enterprise Linux 5 Server (RPMs)" --basearch="x86_64" --releasever="5Server" --product "Red Hat Enterprise Linux Server" --organization "${ORG}"

    log Enable RHEL 5 i386 server
    time hammer -u "${ADMIN_USER}" -p "${ADMIN_PASSWORD}" repository-set enable --name="Red Hat Enterprise Linux 5 Server (RPMs)" --basearch="i386" --releasever="5Server" --product "Red Hat Enterprise Linux Server" --organization "${ORG}"

    #kickstart
    #  time hammer -u "${ADMIN_USER}" -p "${ADMIN_PASSWORD}" repository-set enable --name="Red Hat Enterprise Linux 5 Server (Kickstart)" --basearch="x86_64" --releasever="${RHEL5}" --product "Red Hat Enterprise Linux Server" --organization "${ORG}"
    #  time hammer -u "${ADMIN_USER}" -p "${ADMIN_PASSWORD}" repository-set enable --name="Red Hat Enterprise Linux 6 Server (Kickstart)" --basearch="x86_64" --releasever="${RHEL6}" --product "Red Hat Enterprise Linux Server" --organization "${ORG}"

    log Enable RHEL6 x86_64 content
    time hammer -u "${ADMIN_USER}" -p "${ADMIN_PASSWORD}" repository-set enable --name="Red Hat Enterprise Linux 6 Server (RPMs)" --basearch="x86_64" --releasever="6Server" --product "Red Hat Enterprise Linux Server" --organization "${ORG}"

    log Enable RHEL6 i386 content
    time hammer -u "${ADMIN_USER}" -p "${ADMIN_PASSWORD}" repository-set enable --name="Red Hat Enterprise Linux 6 Server (RPMs)" --basearch="i386" --releasever="6Server" --product "Red Hat Enterprise Linux Server" --organization "${ORG}"

    #  time hammer -u "${ADMIN_USER}" -p "${ADMIN_PASSWORD}" repository-set enable --name="Red Hat Enterprise Linux 7 Server (Kickstart)" --basearch="x86_64" --releasever="${RHEL7}" --product "Red Hat Enterprise Linux Server" --organization "${ORG}"
    log Enable RHEL 7 x86_64 content
    time hammer -u "${ADMIN_USER}" -p "${ADMIN_PASSWORD}" repository-set enable --name="Red Hat Enterprise Linux 7 Server (RPMs)" --basearch="x86_64" --releasever="7Server" --product "Red Hat Enterprise Linux Server" --organization "${ORG}"
}


function sync_content_seq()
{
    log sync content sequentially
    pbench_config
    time hammer -u "${ADMIN_USER}" -p "${ADMIN_PASSWORD}" repository synchronize --id 1 --organization="${ORG}"  2>&1
    time hammer -u "${ADMIN_USER}" -p "${ADMIN_PASSWORD}" repository synchronize --id 2 --organization="${ORG}"  2>&1
    time hammer -u "${ADMIN_USER}" -p "${ADMIN_PASSWORD}" repository synchronize --id 3 --organization="${ORG}"  2>&1
    time hammer -u "${ADMIN_USER}" -p "${ADMIN_PASSWORD}" repository synchronize --id 4 --organization="${ORG}"  2>&1
    time hammer -u "${ADMIN_USER}" -p "${ADMIN_PASSWORD}" repository synchronize --id 5 --organization="${ORG}"  2>&1
    pbench_postprocess
}


function content_view_promote_seq()
{
    log content view promote sequentially
    pbench_config
    user-benchmark --config=$tname-cv-promote-seq -- "./scripts/cv_promote_seq.sh"
    pbench_postprocess
}


function content_view_promote_conc()
{
    log content view promote concurrently
    pbench_config
    user-benchmark --config=$tname-cv-promote-concurrent -- "./scripts/cv_promote_conc.sh"
    pbench_postprocess
}


function content_view_create()
{
    log create content view
    time hammer -u "${ADMIN_USER}" -p "${ADMIN_PASSWORD}" content-view create --name="rhel-5-server-x86_64-cv" --organization="${ORG}" 2>&1
    time hammer -u "${ADMIN_USER}" -p "${ADMIN_PASSWORD}" content-view create --name="rhel-6-server-x86_64-cv" --organization="${ORG}" 2>&1
    time hammer -u "${ADMIN_USER}" -p "${ADMIN_PASSWORD}" content-view create --name="rhel-7-server-x86_64-cv" --organization="${ORG}" 2>&1
    time hammer -u "${ADMIN_USER}" -p "${ADMIN_PASSWORD}" content-view create --name="rhel-5-server-i386-cv" --organization="${ORG}" 2>&1
    time hammer -u "${ADMIN_USER}" -p "${ADMIN_PASSWORD}" content-view create --name="rhel-5-server-i386-cv" --organization="${ORG}" 2>&1

    log add repos to content view
    log add RHEL 5 x86_64 server repo
    time hammer -u "${ADMIN_USER}" -p "${ADMIN_PASSWORD}" content-view add-repository --name="rhel-5-server-x86_64-cv" --organization="${ORG}" --product="Red Hat Enterprise Linux Server" --repository="Red Hat Enterprise Linux 5 Server RPMs x86_64 5Server"  2>&1
    log add RHEL 6 x86_64 server repo
    time hammer -u "${ADMIN_USER}" -p "${ADMIN_PASSWORD}" content-view add-repository --name="rhel-6-server-x86_64-cv" --organization="${ORG}" --product="Red Hat Enterprise Linux Server" --repository="Red Hat Enterprise Linux 6 Server RPMs x86_64 6Server" 2>&1
    log add RHEL 7 x86_64 server repo
    time hammer -u "${ADMIN_USER}" -p "${ADMIN_PASSWORD}" content-view add-repository --name="rhel-7-server-x86_64-cv" --organization="${ORG}" --product="Red Hat Enterprise Linux Server" --repository="Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server" 2>&1
    log add RHEL 5 x86_64 server repo
    time hammer -u "${ADMIN_USER}" -p "${ADMIN_PASSWORD}" content-view add-repository --name="rhel-5-server-i386-cv" --organization="${ORG}" --product="Red Hat Enterprise Linux Server" --repository="Red Hat Enterprise Linux 5 Server RPMs i386 5Server"  2>&1
    log add RHEL 6 x86_64 server repo
    time hammer -u "${ADMIN_USER}" -p "${ADMIN_PASSWORD}" content-view add-repository --name="rhel-6-server-i386-cv" --organization="${ORG}" --product="Red Hat Enterprise Linux Server" --repository="Red Hat Enterprise Linux 6 Server RPMs i386 6Server" 2>&1
}


function content_view_create_scale()
{
    log create content view upto $NUMCV

    for cvnum in `seq 1 $NUMCV`; do
        time hammer -u "${ADMIN_USER}" -p "${ADMIN_PASSWORD}" content-view create --name=cv$cvnum --organization="${ORG}" 2>&1
        time hammer -u "${ADMIN_USER}" -p "${ADMIN_PASSWORD}" content-view add-repository --name=cv$cvnum --organization="${ORG}" --product="Red Hat Enterprise Linux Server" --repository="Red Hat Enterprise Linux 5 Server RPMs x86_64 5Server"  2>&1
        log add RHEL 6 x86_64 server repo
        time hammer -u "${ADMIN_USER}" -p "${ADMIN_PASSWORD}" content-view add-repository --name=cv$cvnum --organization="${ORG}" --product="Red Hat Enterprise Linux Server" --repository="Red Hat Enterprise Linux 6 Server RPMs x86_64 6Server" 2>&1
        log add RHEL 7 x86_64 server repo
        time hammer -u "${ADMIN_USER}" -p "${ADMIN_PASSWORD}" content-view add-repository --name=cv$cvnum  --organization="${ORG}" --product="Red Hat Enterprise Linux Server" --repository="Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server" 2>&1
        log add RHEL 5 x86_64 server repo
        time hammer -u "${ADMIN_USER}" -p "${ADMIN_PASSWORD}" content-view add-repository --name=cv$cvnum --organization="${ORG}" --product="Red Hat Enterprise Linux Server" --repository="Red Hat Enterprise Linux 5 Server RPMs i386 5Server"  2>&1
        log add RHEL 6 x86_64 server repo
        time hammer -u "${ADMIN_USER}" -p "${ADMIN_PASSWORD}" content-view add-repository --name=cv$cvnum --organization="${ORG}" --product="Red Hat Enterprise Linux Server" --repository="Red Hat Enterprise Linux 6 Server RPMs i386 6Server" 2>&1
    done
}


function content_view_publish_scale()
{
    log content view publish at scale
    for numcvpublish  in `seq 1 ${NUM_CV_PUBLISH}`; do
    pbench_config
    chmod +x scripts/cv_publish_scale.sh
    user-benchmark  --config=$tname-cv-publish-cv:$NUMCV-cvpublishno:$numcvpublish -- "./scripts/cv_publish_scale.sh"
    pbench_postprocess
    sleep 10
    done
}


function content_view_publish()
{
    log content view publish
    chmod +x scripts/cv_publish.sh
    user-benchmark --tool-group=sat6 --config=$tname-cv-publish -- "./scripts/cv_publish.sh"
}


function sync_content_conc()
{
    log sync content repos concurrently
    pbench_config
    user-benchmark  --config=$tname-sync-repos -- "./scripts/sync_content.sh"
    pbench_postprocess
}


function install_capsule()
{
    log instll capsules
    OS_MAJOR_VERSION=`sed -rn 's/.*([0-9])\.[0-9].*/\1/p' /etc/redhat-release`
    HOSTNSAME=`hostname`
    rm -rf scripts/capsule.repo
    echo "[CAPSULEREPO]" >> scripts/capsule.repo
    echo "name=capsulerepo" >> scripts/capsule.repo
    echo "baseurl=$SAT_REPO/latest-Satellite-$SAT_VERSION-RHEL-$OS_MAJOR_VERSION/compose/Capsule/x86_64/os/" >> scripts/capsule.repo
    echo "enabled=1" >> scripts/capsule.repo
    echo "gpgcheck=0" >> scripts/capsule.repo

    pulp_oauth_secret=$(awk '{print $2}' /var/lib/puppet/foreman_cache_data/katello_oauth_secret)
    foreman_oauth_secret=$(awk '{print $2}' /var/lib/puppet/foreman_cache_data/oauth_consumer_secret)
    foreman_oauth_key=$(awk '{print $2}' /var/lib/puppet/foreman_cache_data/oauth_consumer_key)

    for  capsule in $CAPSULES; do

    echo 'subscription-manager register --username='$RHN_USERNAME' --password='$RHN_PASSWORD' --force' >> scripts/capsule_install_$capsule.sh
    echo 'subscription-manager attach --pool='$pool_id'' >> scripts/capsule_install_$capsule.sh
    cat scripts/capsule_install.sh >> scripts/capsule_install_$capsule.sh
    echo 'subscription-manager register --org "Default_Organization"  --username '$ADMIN_USER' --password '$ADMIN_PASSWORD' --force' >> scripts/capsule_install_$capsule.sh
    echo 'rpm -Uvh http://'$HOSTNAME'/pub/katello-ca-consumer-latest.noarch.rpm' >> scripts/capsule_install_$capsule.sh
    echo  'capsule-installer --parent-fqdn          "'$HOSTNAME'"\
                 --register-in-foreman  "true"\
                 --foreman-oauth-key    "'$foreman_oauth_key'"\
                 --foreman-oauth-secret "'$foreman_oauth_secret'"\
                 --pulp-oauth-secret    "'$pulp_oauth_secret'"\
                 --certs-tar            "/root/'"$capsule"'-certs.tar"\
                 --puppet               "true"\
                 --puppetca             "true"\
                 --pulp                 "true"' >>  scripts/capsule_install_$capsule.sh

        #clear old certs if any
        if [ -f ~/$capsule-certs.tar ]; then
            rm -rf ~/$capsule-certs.tar
        fi
        capsule-certs-generate --capsule-fqdn $capsule --certs-tar $capsule-certs.tar

        scp -o "${SSH_OPTS}" ~/$capsule-certs.tar root@$capsule:.
        scp -o "${SSH_OPTS}" scripts/capsule.repo root@$capsule:/etc/yum.repos.d/
        scp -o "${SSH_OPTS}" scripts/requirements-capsule.txt root@$capsule:.
        scp -o "${SSH_OPTS}" scripts/capsule_install_$capsule.sh root@$capsule:.
        ssh -o "${SSH_OPTS}" root@$capsule "chmod +x capsule_install_$capsule.sh"
        ssh -o "${SSH_OPTS}" root@$capsule " ./capsule_install_$capsule.sh"

        rm -rf scripts/capsule_install_$capsule.sh
    done
}


function sync_capsule_conc()
{
    log sync capsules concurrently
    numcapsules=0;
    for capsule in $CAPSULES; do numcapsules=`expr ${numcapsules} + 1`; done
    for numcap in `seq 1 ${numcapsules}`; do
        capid=`expr ${numcap} + 1`
        #add Lifecycle environment
        hammer -u "${ADMIN_USER}" -p "${ADMIN_PASSWORD}" capsule content add-lifecycle-environment --environment-id 1 --id "${capid}"
        #clear tools if already registered
    done
    #clear capsules
    for capsule in $CAPSULES;  do
        ssh -o "${SSH_OPTS}" root@$capsule "clear-results; clear-tools; kill-tools"
    done
    #Register tools
    register-tool-set
    for capsule in $CAPSULES;  do
        ssh -o "${SSH_OPTS}" root@$capsule "register-tool-set"
    done
    user-benchmark --config=${tname}-capsule-sync-concurrent -- "./scripts/sync_capsules.sh ${numcapsules} ${tname}"
    for numcap in `seq 1 ${numcapsules}`; do
        capid=`expr ${numcap} + 1`
        hammer -u "${ADMIN_USER}" -p "${ADMIN_PASSWORD}" capsule content remove-lifecycle-environment --environment-id 1 --id "${capid}"
    done
    clear-tools; kill-tools
    for capsule in $CAPSULES;  do
        ssh -o "${SSH_OPTS}" root@$capsule "clear-results; clear-tools; kill-tools"
    done
}


function register_content_host_conc()
{
    log
}


function register_content_host_seq()
{
    log
}


function remove_capsule()
{
    log remove capsules if, any registered
    for  capsule in $CAPSULES; do
        scp scripts/capsule-remove root@$capsule:/usr/sbin/
        ssh -o "${SSH_OPTS}" root@$capsule "rm -rf /home/backup/ ;  capsule-remove"
    done
}


function sat_backup()
{
    log backup satelitte
    rm -rf /home/backup
    time  katello-backup /home/backup
}


function restore_backup()
{
    log restoring satellite from backup
    time katello-restore /home/backup/
}


function install()
{
    python install_satelite.py
}


opts=$(getopt -q -o jic:t:b:sd:r: --longoptions "help,install,sat-backup,sat-restore,setup,upload,add-product,create-life-cycle,enable-content,content-view-create,content-view-publish,sync-content,resync-content,install-capsule,sync-capsule,register-content-hosts,remove-capsule,all" -n "getopt.sh" -- "$@");

eval set -- "$opts";
while true; do
    case "$1" in
    --help)
        satperf_usage
        exit
        ;;
    --install)
        echo "install"
        time python install_satelitte.py
        #install
        shift
        ;;
    --sat-backup)
        sat_backup
        shift
        ;;
    --sat-restore)
        restore_backup
        shift
        ;;
    --setup)
        pbench_config
        shift
        ;;
    --upload)
        upload_manifest
        shift
        ;;
    --add-product)
        add_products
        shift
        ;;
    --create-life-cycle)
        create_life_cycle_env
        shift
        ;;
    --enable-content)
        enable_content
        shift
        ;;
    --content-view-create)
        if $CVSCALE ; then
            content_view_create_scale
        else
            content_view_create
        fi
        shift
        ;;
    --content-view-publish)
        if $CVSCALE ; then
            content_view_publish_scale
        else
            content_view_publish
        fi
        shift
        ;;
    --content-view-promote)
        if $CVSCALE ; then
            content_view_promote_conc
        else
            content_view_promote_seq
        fi
        shift
        ;;
    --sync-content)
        if $CONCURRENT ; then
            sync_content_conc
        else
            sync_content_seq
        fi
        shift
        ;;
    --resync-content)
        if $CONCURRENT ; then
            sync_content_conc
        else
            sync_content_seq
        fi
        shift
        ;;
    --install-capsule)
        install_capsule
        shift
        ;;
    --sync-capsule)
        if $CONCURRENT ; then
            sync_capsule_conc
        else
            sync_capsule_seq
        fi
        shift
        ;;
    --register-content-hosts)
        if $CONCURRENT ; then
            register_content_host_conc
        else
            register_content_host_seq
        fi
        shift
        ;;
    --remove-capsule)
        remove_capsule
        shift
        ;;
    --all)
        python install_satelite.py
        sat_backup
        upload_manifest
        enable_content
        sleep 10
        sync_content
        install_capsule
        sync_capsule
        shift
        ;;
    --)
        shift
        break
        ;;
    esac
done
