# Soak Test Automation

## Introduction
---
The playbooks present in this directory serve the purpose of automating the soak test efforts
that are happening for the upcoming releases.

Currently automated tasks include:
- Repository Enablement and Sync
- Environment creation
- Sync Plan Creation
- Content View Creation
- Content View Publish
- Content View Promotion
- Puppet Product Creation
- Puppet Forge Repo Creation
- Remote Execution package install
- Host patching through Goferd
- Host patching through Remote Execution

## Configuration
---
All the configuration for the soak tests is stored inside a centralized file *conf/soak_test.yaml*

Currently the configuration allows only the repo sync to be customized by adding or removing the
products under the soak_repos dictionary.

## Executing Playbooks
---
- To create a sync plan the following command needs to be executed

```bash
ansible-playbook -i conf/hosts.ini playbooks/soak-tests/sync-plan.yaml
```

- To create, publish and promote content views, the following command needs to be executed

```bash
ansible-playbook -i conf/hosts.ini playbooks/soak-tests/content-setup.yaml
```

- To run a content view publish task only, the following command needs to be executed

```bash
ansible-playbook -i conf/hosts.ini playbooks/soak-tests/content-view-publish.yaml
```

- To run a content view promote task only, the following command needs to be executed

```bash
ansible-playbook -i conf/hosts.ini playbooks/soak-tests/content-view-promote.yaml
```

- To run a errata install, the following command needs to be executed

```bash
ansible-playbook -i conf/hosts.ini playbooks/soak-tests/errata-apply.yaml
```

- To run a Remote execution based package install, the following command needs to be executed

```bash
ansible-playbook -i conf/hosts.ini playbooks/soak-tests/rex-job.yaml --extra-vars "package_name=<name_of_package_to_install>"
```
