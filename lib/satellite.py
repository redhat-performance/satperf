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

    def __init__(self, _conf=None, _logger=None):
        super(SatelliteCore, self).__init__()
        self.config = _conf
        self.logger = _logger
        # load other settings and modules
        self.__load_settings()
        self.PbenchController = PbenchActions()
        self.SatelliteAPIController = SatelliteAPI()

    def __load_settings(self):
        self.HOSTS_INI_FILE = self.config.get("Settings", "hosts")
        self.TNAME = self.config.get("Settings", "tname")
        self.TEST_PREFIX = "satellite-%s" % self.TNAME
        self.__build_rhn_metadata()
        self.__build_sat_metadata()
        self.__build_pbench_metadata()

    def __build_rhn_metadata(self):
        self.user = self.config.get('RHN','user')
        self.passwd = self.config.get('RHN','passwd')
        self.pool_id = self.config.get('RHN','pool_id')
        self.admin_user = self.config.get('RHN','admin_user')
        self.admin_pass = self.config.get('RHN','admin_pass')
        self.org = self.config.get('RHN','org')
        self.location = self.config.get('RHN','location')

    def __build_sat_metadata(self):
        self.sat_repo = self.config.get('Satellite','repo')
        self.sat_version = self.config.get('Satellite','version')
        self.RHEL5_RELEASE = self.config.get('Satellite','rhel5')
        self.RHEL6_RELEASE = self.config.get('Satellite','rhel6')
        self.RHEL7_RELEASE = self.config.get('Satellite','rhel7')
        self.capsule_servers = self.config.get('Satellite','capsules')
        self.content_repo_server = self.config.get('Satellite','rediscover')
        self.SAT_REPO_COUNT = self.config.get('Satellite','repo_count')
        self.CV_SCALE = bool(self.config.get('Satellite','cv_scale'))
        self.CV_SCALE_COUNT = self.config.get('Satellite','cv_count')
        self.CV_PUB_COUNT = self.config.get('Satellite','cv_pub')
        self.CONCURRENT = bool(self.config.get("Satellite", "concurrent"))
        self.manifest_file = self.config.get('Satellite','manifest')
        self.backup_path = self.config.get('Satellite','backup_path')

    def __build_pbench_metadata(self):
        self.pbench_enabled = self.config.get('Pbench','enabled')
        self.pbench_repo_server = self.config.get('Pbench','pbench_repo')
        self.products = self.config.get('Pbench','products')

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
        if nargs.register_content_hosts:
            self.register_content_host()
        if nargs.remove_capsule:
            self.remove_capsule()
        if nargs.resync_content or nargs.sync_content:
            self.sync_content()
        if nargs.sat_backup:
            self.backup_satellite(_path='/home/backup')
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

    def prepare_runner(self, pb_name, options={}, tasks=[],
                        _extra_vars={}, verbosity=3):
        # msg = "[Py Ansible API v2.1] is unstable"
        # self.logger.warn(msg)
        _playbook_path = os.path.join(BASE_DIR,
                                     'playbooks/satellite/', pb_name)
        #import pdb; pdb.set_trace()
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
            #private_key_file="/path/to/key.pem",
            #vault_password=vaultpass,
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
