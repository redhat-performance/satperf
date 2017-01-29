# satellite-performance

Table of Contents
=================

- [Satellite-performance: What does it have?](#satellite-performance)
- [Installation](#installation)
  - [Installation Prerequisites](#installation-prerequisites)
  - [Installation Steps](#installation-steps)
- [Execution](#execution)
- [Ansible for satellite-performance](#ansible-for-satellite-performance)
    - [Getting Started](#install-systems-on-aws)
    - [sync repos](#sync-repos-to-satellite)
    - [Performance Check](#performance-check)
    - [Performance Tune](#performance-tune)
    - [Adjust your overcloud](#adjust-your-overcloud)

# Satellite-performance

This project was started to run performance tests on Red Hat Satelitte.
It does the following activities:

 - Satelitte installation
 - Uploads manigfest, updates repo
 - Concurrently syncs multiple repositories from repo server
 - Creates lifecycle environments
 - Creates capsules
 - Concurrently  syncronizes multiple capsules
 - ..etc

It also provides a way to measure time for tests while capturing resources
using [pbench](https://github.com/distributed-system-analysis/pbench)

# Ansible for satellite-performance

Ansible is used to perform most of the work. There are playbooks for:

 - Installing satellite
 - Installing capsule
 - Registering containers as hosts to capsule
 - Install ketello-agent and run errata
 - Sync content
 - Puppet module update

# INSTALLATION

### PREREQUISITES

This is a Python 2 based project. 
Install pip, virtualenv and run `source ./setup` from root. 

The above script does the following:

 - exports `ANSIBLE_CONFIG=$PWD/conf/ansible.cfg`
 - checks for RPM packages: `gcc python-devel openssl-devel libffi-devel`
 - check for virtualenv settings

### Note

1. Before running satellite-performance, check `conf/satperf.yaml`, and create `conf/satperf.local.yaml`
   and configure any owerrides there (e.g. RHN credentials, Satellite setup details etc).

2. Make sure that all hosts you are going to use have SSH certificate deployed for
   user root and private certificate is configured in your `conf/satperf.local.yaml`.

3. Save your Satellite manifest as `conf/manifest.zip` or elsewhere and configure path
   in your `conf/satperf.local.yaml`.

4. If you are going to use sateperf to setup your docker hosts, pay special
   attention to their partitioning. In setup satperf uses, we need empty disk
   partition (`/dev/vda3` by default) where LVM logical group "docker" will
   be created and docker will be configured to use that. There are two very
   simple pre-created roles for that: `playbooks/satellite/roles/docker-host-kvm-partitioning`
   and `.../docker-host-ec2-partitioning`. Please choose one or create new
   one byt setting `docker_host_partitioning` in config to "kvm" or "ec2" or
   add new one and alter `playbooks/satellite/docker-host.yaml`

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
$ ansible-playbook --private-key conf/id_rsa -i conf/hosts.ini playbooks/satellite/docker-host.yaml
```

### To prepare Satellite:

```
$ ansible-playbook --private-key conf/id_rsa -i conf/hosts.ini playbooks/satellite/installation.yaml
```

### To prepare Capsules:

```
$ ansible-playbook --private-key conf/id_rsa -i conf/hosts.ini playbooks/satellite/capsules.yaml
```

###  To install Collectd:

```
$ ansible-playbook --private-key conf/id_rsa -i conf/hosts.ini playbooks/monitoring/collectd-generic.yaml --tags "satellite6"
```
...Replace "satellite6" with whatever machines you intend to install collectd on.

### To install collectd->graphite dashboards:

```
$ ansible-playbook --private-key conf/id_rsa -i conf/hosts.ini playbooks/monitoring/dashboards-generic.yaml
```

#### If collectd fails to send metrics to your grafana instance

You might wanna check the selinux policies. Try one of the following to counter "Permission Denied" log statement:

```
# setsebool -P collectd_tcp_network_connect 1
```

OR

```
# audit2allow -a
# audit2allow -a -M collectd_t
# semodule -i collectd_t.pp
```

OR

```
# semanage permissive -a httpd_t
```

..or all.
