# satperf

Table of Contents
=================

- [Satperf: What does it have?](#satperf)
- [Installation](#installation)
  - [Installation Prerequisites](#installation-prerequisites)
  - [Installation Steps](#installation-steps)
- [Execution](#execution)
- [Ansible for satperf](#ansible-for-satperf)
    - [Getting Started](#install-systems-on-aws)
    - [sync repos](#sync-repos-to-satellite)
    - [Performance Check](#performance-check)
    - [Performance Tune](#performance-tune)
    - [Adjust your overcloud](#adjust-your-overcloud)

# Satperf

This project was started to run performance tests on Redhat Satelitte.
satperf needs to be run from Satelitte server. It does the following activities:

  - Satelitte installation
  - uploads manigfest, updates repo
  - concurrently syncs multiple Repositories from Repo Server
  - creates lifecycle environments
  - creates capsules
  - concurrently  syncronizes multiple capsules
  - ..etc

It also provides a way to measure time for tests while capturing resources
using [pbench](https://github.com/distributed-system-analysis/pbench)

# Ansible for satperf

Playbooks for:
* Installing satellite
* Installing capsule
* Registering containers as hosts to capsule
* Install ketello-agent and run errata
* sync content
* Puppet module update

# INSTALLATION

### PREREQUISITES

From project root, run: `source ./setup`

The above script does the following: 

 - exports `ANSIBLE_CONFIG=$PWD/conf/ansible.cfg`
 - checks for RPM packages: `gcc python-devel openssl-devel libffi-devel`
 - check for virtualenv settings

### Note

1. Before Running satperf, update conf/satperf.conf for general settings,
   RHN credentials, satellite setup details and pbench settings.

2. Make a copy public keys of satellite server and capsules.

3. Callback plugins for this project lie in `lib/playground/callback_plugins`,
   in case you feel like tweaking the output.

4. Save your Satellite manifest as `playbooks/satellite/roles/satellite-populate/files/manifest.zip`.

# Execution

### To run with Ansible's Python2 API

For help:

```
(venv) $ ./satperf.py -h
```

Example, for installation, run:

```
(venv) $ ./satperf.py -s
```

### To run with raw ansible-playbook commands on commandline


### To prepare Docker hosts:

```
  $ ansible-playbook -v -i conf/hosts.ini playbooks/satellite/docker-host.yaml
```

### To prepare Satellite:

```
  $ ansible-playbook -v -i conf/hosts.ini playbooks/satellite/installation.yaml
```

### To prepare Capsules:

```
  $ ansible-playbook -v -i conf/hosts.ini playbooks/satellite/capsules.yaml
```

### To install systems in AWS:

```
  # rpm -q python2-boto || yum -y install python2-boto
  $ export AWS_ACCESS_KEY_ID='AK123'
  $ export AWS_SECRET_ACCESS_KEY='abc123'
  $ ansible-playbook -i conf/hosts.ini playbooks/{}/aws.yaml
```

### To sync repos so we can have it locally:

```
  # cat /etc/yum.repos.d/reposync.repo
  [Satellite-6.1.0-RHEL-6-20160321.0-Satellite-x86_64]
  name=Satellite-6.1.0-RHEL-6-20160321.0/compose/Satellite/x86_64
  baseurl=http://remote.server.example.com/devel/candidate-trees/Satellite/Satellite-6.1.0-RHEL-6-20160321.0/compose/Satellite/x86_64/os/
  enabled=0
  gpgcheck=0

  [Satellite-6.1.0-RHEL-6-20160321.0-Capsule-x86_64]
  name=Satellite-6.1.0-RHEL-6-20160321.0/compose/Capsule/x86_64
  baseurl=http://remote.server.example.com/devel/candidate-trees/Satellite/Satellite-6.1.0-RHEL-6-20160321.0/compose/Capsule/x86_64/os/
  enabled=0
  gpgcheck=0
  # cd /var/www/html/repos
  # reposync --downloadcomps --repoid Satellite-6.1.0-RHEL-6-20160321.0-Satellite-x86_64
  # cd Satellite-6.1.0-RHEL-6-20160321.0-Satellite-x86_64
  # createrepo --groupfile comps.xml .
  # cd ..
  ### Repeat for the Capsule repo


```

### To display facts stored by Ansible about all hosts (warning: looks like

it is quite expensive operation):
```
  $ ansible capsule61.example.com -i conf/hosts.ini --user=root -m setup
```

###  To install Collectd:

```
# ansible-playbook -i conf/hosts.ini playbooks/monitoring/collectd-generic.yml --tags "sat6"
```
...Replace "sat6" with whatever machines you intend to install collectd on.

### To install collectd->graphite dashboards:

```
# ansible-playbook -i conf/hosts.ini playbooks/monitoring/dashboards-generic.yml --tags "collectd-generic"
```
...Replace "sat6" with whatever machines you intend to install collectd on.

#### If collectd fails to send metrics to your grafana instance

You might wanna check the selinux policies. Try one of the following to counter "Permission Denied" log statement:

```
setsebool -P collectd_tcp_network_connect 1
```

OR

```
audit2allow -a
audit2allow -a -M collectd_t
semodule -i collectd_t.pp
```

..or both.
