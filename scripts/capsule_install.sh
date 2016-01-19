log installing pre-reqs

yum install -y capsule-installer pulp-rpm-plugins ntp mod_wsgi pulp-nodes-parent python-pulp-puppet-common createrepo httpd python-celery pyparsing mod_ssl pytz python-imaging genisoimage python-ldap pulp-server python-mongoengine foreman-proxy mongodb-server rubygem-bundler qpid-cpp-client pulp-katello python-rhsm subscription-manager pulp-nodes-child puppet-server python-crane python-qpid-qmf python-qpid qpid-tools mailcap qpid-dispatch-router rubygem-smart_proxy_pulp katello-debug katello-agent katello-certs-tools mongodb mod_passenger pulp-docker-plugins pulp-selinux pulp-puppet-plugins yum-utils.noarch katello-installer-base

service ntpd start; chkconfig ntpd on
systemctl stop firewalld
chkconfig firewalld off
