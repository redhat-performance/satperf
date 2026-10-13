Ansible CNV host manager
========================

This repo manages bastion-side automation for CNV/OCP deployment via
[`jetlag`](https://github.com/redhat-performance/jetlag).

Current scope:

- clone/update `jetlag` on the generated `bastion` host
- copy the SSH key and pull secret needed by `jetlag`
- render a BYOL-style Jetlag inventory from the satperf-generated inventory
- render `ansible/vars/all.yml` with CNV explicitly enabled
- run `ansible/setup-bastion.yml`
- run `ansible/mno-deploy.yml`

The playbook intentionally treats:

- `bastion` as the Jetlag execution host
- `cnv_controlplane` as the physical OCP control-plane host set
- `cnv_workers` as the authoritative Jetlag worker-capable/schedulable host set

Usage from `satperf/conf/contperf/doit.sh`:

```bash
ansible-playbook -i conf/contperf/inventory.blue.ini ansible-cnv-host-mgr/jetlag.yaml
```

Expected extra vars include:

- `jetlag_repo_url`
- `jetlag_repo_ref`
- `jetlag_dest`
- `jetlag_pull_secret_file`
- `jetlag_lab_cloud`
- `jetlag_cluster_name`
- `jetlag_base_dns_name`
- `jetlag_ssh_private_key_file`
- `jetlag_ssh_public_key_file`
- `jetlag_bmc_password`

Optional vars are used for:

- lab/cloud identification
- OCP version/build
- base DNS / cluster naming
- public VLAN behavior
- explicit interface overrides
- control-plane network defaults
- setup-only runs (`jetlag_setup_only=true`)
- optional iDRAC reset before Dell virtual-media boot (`jetlag_reset_idrac=true`)
