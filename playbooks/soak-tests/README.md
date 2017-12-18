# Soak Test Automation

## Introduction
---
The playbooks present in this directory serve the purpose of automating the soak test efforts
that are happening for the upcoming releases.

Currently automated tasks include:
- Repository Enablement and Sync
- Environment creation
- Sync Plan Creation

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
