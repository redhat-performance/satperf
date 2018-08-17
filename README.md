# satellite-performance

## What is satellite-performance

This project was started to run performance tests on Red Hat Satellite 6.
It does the following activities:

 - Satellite installation
 - Uploads manifest, updates repo
 - Concurrently syncs multiple repositories from repo server
 - Creates lifecycle environments
 - Creates capsules
 - Concurrently  syncronizes multiple capsules
 - ..etc

It also provides a way to measure time for tests while capturing resources
using collectd.

### Ansible for satellite-performance

Ansible is used to perform most of the work. There are playbooks for:

 - Installing satellite
 - Installing capsule
 - Registering containers as hosts to capsule
 - Install katello-agent and run errata
 - Sync content
 - Puppet module update

## Installation

### Prerequisities

You need Ansible installed.

### Configuration

1. Before running satellite-performance, check `conf/satperf.yaml`, and create `conf/satperf.local.yaml`
   and configure any overrides there (e.g. RHSM credentials, Satellite setup details etc).

2. Make sure that all hosts you are going to use have SSH certificate deployed for
   user root and private certificate is configured in your `conf/satperf.local.yaml`.

3. Save your Satellite manifest as `conf/manifest.zip` or elsewhere and configure path
   in your `conf/satperf.local.yaml`.

4. If you are going to use satperf to setup your docker hosts, pay special
   attention to their partitioning. There are few very simple pre-created
   roles like: `playbooks/satellite/roles/docker-host-kvm-partitioning`
   and `.../docker-host-ec2-partitioning`. Please choose one or create new
   one byt setting `docker_host_partitioning` in config to "kvm" or "ec2" or
   add new one and alter `playbooks/satellite/docker-host.yaml`

## Usage


### To prepare Docker hosts:

```
$ ansible-playbook --private-key conf/id_rsa -i conf/hosts.ini playbooks/docker/docker-host.yaml
```

### To prepare Satellite:

```
$ ansible-playbook --private-key conf/id_rsa -i conf/hosts.ini playbooks/satellite/installation.yaml --skip-tags "non-async"
```

### To prepare Capsules:

```
$ ansible-playbook --private-key conf/id_rsa -i conf/hosts.ini playbooks/satellite/capsules.yaml --skip-tags "non-async"
```

### To install Collectd:

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
