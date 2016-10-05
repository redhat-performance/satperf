#!/usr/bin/env python

import os
import sys
import json
import time
# import shutil
# import subprocess
# from pssh import ParallelSSHClient, utils

from ansible import inventory, \
    callbacks, playbook

from satutils import SatelliteActions, \
    SatelliteAPI, \
    MonitoringActions, \
    PbenchActions

# PROJECT_LOC=''
# sys.path.append("%s" % PROJECT_LOC)
BASE_DIR = os.path.join(os.path.dirname(__file__), '..')


class SatelliteCore(SatelliteActions, MonitoringActions):
    """
    parse arguments supplied for satperf and
    take actions accordingly
    """

    SATELLITE_VERSION = 6.2

    def __init__(self, _conf=None, _logger=None, _hosts=None):
        super(SatelliteCore, self).__init__()
        self.config = _conf
        self.logger = _logger
        # load other settings and modules
        self.__load_settings()
        self.PbenchController = PbenchActions()
        self.SatelliteAPIController = SatelliteAPI()

    def __load_settings(self):
        self.HOSTS_INI_FILE = self.config["satperf_hosts"]
        self.PRIVATE_KEY = self.config["satperf_private_key"]

    def __prepare_runner_metadata(self, options, tasks):
        # # tags in the tasks section of YAML playbook
        # TASKS = ['simple', '_playbookcheck_path',
        #          'debug', 'sequence_count',
        #          'random_choice', 'until_find',
        #          'indexed_items', 'template']
        _opts = options
        # 'subset': '~^localhost',
        # 'become': True,
        # 'become_method': 'sudo',
        # 'become_user': 'root',
        # 'private_key_file': '/path/to/the/id_rsa',
        # 'tags': TASKS[:],
        # 'skip_tags': 'debug',
        _opts['verbosity'] = 1
        if tasks:
            _opts['tags'] = tasks
        return _opts

    def init_actions(self, nargs):
        if nargs.add_product:
            self.add_products()
        if nargs.all:
            self.all()
        if nargs.content_view_create:
            self.content_view_create()
        if nargs.content_view_publish:
            self.content_view_publish()
        if nargs.create_life_cycle:
            self.create_life_cycle()
        if nargs.enable_content:
            self.enable_content()
        if nargs.upload_dashboard_grafana:
            self.upload_dashboard_grafana()
        if nargs.register_content_hosts:
            self.register_content_host()
        if nargs.remove_capsule:
            self.remove_capsule()
        if nargs.setup_monitoring:
            if self.record_response("Installing Collectd") == 'y':
                tags = self.config['Monitoring']['hosts'].split(':')
                self.install_collectd(tags)
            if self.record_response("Installing Graphite") == 'y':
                self.install_graphite()
            if self.record_response("Installing Grafana") == 'y':
                self.install_grafana()
            # if self.record_response("Installing ELK") == 'y':
            #     self.install_elk()
            # if self.record_response("Preparing ELK client") == 'y':
            #     self.prepare_elk_client()
        if nargs.resync_content or nargs.sync_content:
            self.sync_content()
        if nargs.sat_backup:
            self.backup_satellite()
        if nargs.sat_restore:
            self.store_backup()
        if nargs.setup:
            if self.record_response("Installing Satellite") == 'y':
                self.install_satellite()
            if self.record_response("Installing Capsules") == 'y':
                self.install_capsule()
            if self.record_response("Preparing Docker Hosts") == 'y':
                self.prepare_docker_hosts()
        if nargs.sync_capsule:
            self.sync_capsule()
        if nargs.upload:
            self.upload_manifest()
        if nargs.run_playbook:
            self.run_a_playbook(nargs.run_playbook)

    def prepare_runner(self, _playbook_path, options={}, tasks=None,
                        _extra_vars={}, verbosity=3):
        _OPTIONS = self.__prepare_runner_metadata(options, tasks)
        _vb = _OPTIONS['verbosity']
        _inventory = inventory.Inventory(self.HOSTS_INI_FILE)
        stats = callbacks.AggregateStats()
        playbook_cb = callbacks.PlaybookCallbacks(verbose=_vb)
        runner_cb = callbacks.PlaybookRunnerCallbacks(stats,
                                             verbose=_vb)

        runner = playbook.PlayBook(
            playbook=_playbook_path,
            inventory=_inventory,
            extra_vars=_extra_vars,
            private_key_file=self.PRIVATE_KEY,
            #vault_password=vaultpass,
            only_tags=tasks,
            stats=stats,
            callbacks=playbook_cb,
            runner_callbacks=runner_cb
        )

        return runner

    def process_stats(self, pb):
        hosts = sorted(pb.stats.processed.keys())
        failed_hosts = []
        unreachable_hosts = []
        for h in hosts:
            t = pb.stats.summarize(h)
            if t['failures'] > 0:
                failed_hosts.append(h)
            if t['unreachable'] > 0:
                unreachable_hosts.append(h)

        self.logger.info("failed hosts: %s" % failed_hosts)
        self.logger.info("unreachable hosts: %s" % unreachable_hosts)

        retries = failed_hosts + unreachable_hosts
        self.logger.info("retries: %s" % retries)

        if len(retries) > 0:
            return 1
        return 0

    def record_response(self, msg):
        msg = "\n =======> %s..\nContinue (y/n)?: " % msg
        if sys.version_info[0] < 3:
            # add py2 compatible input statement
            return raw_input(msg).lower()
        else:
            # add this in case py3 + ansible issue is solved:
            # ref: https://github.com/ansible/ansible/issues/16013
            return input(msg).lower()
