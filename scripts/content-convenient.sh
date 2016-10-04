#!/bin/sh

set -e

echo "##### Make sure we have the daemonize package #####"
ls /var/www/html/pub/daemonize-*.rpm || wget -O /var/www/html/pub/daemonize-1.7.7-1.el7.x86_64.rpm http://dl.fedoraproject.org/pub/epel/7/x86_64/d/daemonize-1.7.7-1.el7.x86_64.rpm

echo "##### Create puppet module #####"
PUPPET_MODULE=puppet-qaredhattest
PUPPET_MODULE_FILE=/tmp/puppet-qaredhattest.txt
PUPPET_MODULE_FILE_CONTENT="Some important sentence."
rm -rf $PUPPET_MODULE
puppet module generate "$PUPPET_MODULE" --skip-interview
cat <<EOF > $PUPPET_MODULE/manifests/init.pp
class qaredhattest {
  file { "$PUPPET_MODULE_FILE":
    ensure => file,
    mode   => 755,
    owner  => root,
    group  => root,
    content => "$PUPPET_MODULE_FILE_CONTENT",
  }
}
EOF
puppet module build $PUPPET_MODULE

echo "##### Upload puppet module #####"
PUPPET_PRODUCT='MyPuppetProduct'
PUPPET_REPO='MyPuppetRepo'
hammer --username admin --password changeme product create --label $PUPPET_PRODUCT --name $PUPPET_PRODUCT --organization-id 1
hammer --username admin --password changeme repository create --content-type puppet --label $PUPPET_REPO --name $PUPPET_REPO --organization-id 1 --product $PUPPET_PRODUCT
hammer --username admin --password changeme repository upload-content --name $PUPPET_REPO --path $PUPPET_MODULE/pkg/$PUPPET_MODULE-0.1.0.tar.gz --product $PUPPET_PRODUCT --organization-id 1

echo "##### Create package repos #####"
hammer -u admin -p changeme product create --organization-id 1 --name "RHEL7 x86_64 Base"
hammer --username admin --password changeme repository create --content-type yum --label "rhel7-x86_64-base" --name "RHEL7 x86_64 Base" --organization-id 1 --product "RHEL7 x86_64 Base" --url "..."
hammer -u admin -p changeme product create --organization-id 1 --name "Sat6.2 Tools Beta"
hammer --username admin --password changeme repository create --content-type yum --label "sat62-tools-beta" --name "Sat6.2 Tools Beta" --organization-id 1 --product "Sat6.2 Tools Beta" --url "..."

echo "##### Synchronize in background #####"
hammer -u admin -p changeme repository synchronize --organization-id 1 --product "RHEL7 x86_64 Base" --name "RHEL7 x86_64 Base" --async
hammer -u admin -p changeme repository synchronize --organization-id 1 --product "Sat6.2 Tools Beta" --name "Sat6.2 Tools Beta" --async

echo "##### Create content view #####"
hammer -u admin -p changeme content-view create --name "test" --organization-id 1
hammer -u admin -p changeme content-view add-repository --name "test" --organization-id 1 --product "RHEL7 x86_64 Base" --repository "RHEL7 x86_64 Base"
hammer -u admin -p changeme content-view add-repository --name "test" --organization-id 1 --product "Sat6.2 Tools Beta" --repository "Sat6.2 Tools Beta"
hammer -u admin -p changeme content-view puppet-module add --organization-id 1 --content-view "test" --name "qaredhattest" --author "puppet"

echo "##### Publish and promote content view #####"
hammer -u admin -p changeme content-view publish --name "test" --organization-id 1 --async
