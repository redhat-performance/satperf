# General

### Priority
- [ ] add cleanup scripts

### Backlog

- [ ]

-----

# Playbooks

## Monitoring

### Priority
- [ ] carbon-cache: /etc/graphite-web/local_settings.py -> change SECRET_KEY and ALLOWED_HOSTS
- [x] groupadd collectd
- [x] collectd.conf
  - [x] hostname change from IP -> something
  - [ ] prepend satellite62.ec2_satellite62 (change this)
  - [x] debug turbostat (unsupported cpu on ec2 - msg: not APERF) and also, postgresql-gutterman failure

### Backlog

- [x] connect monitoring to satperf
- [ ] Add iptables -F filters
- [ ] grafana dashboard -> add datasource

## Satellite

### Priority

- [ ] connect generic.yaml and cred.yaml to variables loaded from conf/satperf.conf
  - [ ] sort attach pool id, RHN registration creds etc with content hosts
  - [x] sort capsules var set in satperf.conf and hosts.ini
- [ ] handle Dockerpod_file
- [ ] connect scripts/ to satellite playbooks
- [ ] create vms from satperf

### Backlog

- [ ] integrate pbench
- [ ] integrate content-view-promote
  - [ ] scripts/ missing.
- [ ] integrate content-view-publish
  - [ ] connect scripts
- [ ] integrate health check
