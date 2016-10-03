#!/usr/bin/env python

# A word of advice for developers (although should be obvious):
# 'SatelliteActions' and 'MonitoringActions' are inherited into
# 'satellite.py:SatelliteCore' class. So both of these classes
# should contain differently named methods to avoid clashes possible
# due to multiple inheritance in Python. For more on this, lookup:
# - Method Resolution Order in Python
#   http://python-history.blogspot.in/2010/06/method-resolution-order.html
# - Diamond Problem
#   https://en.wikipedia.org/wiki/Multiple_inheritance#The_diamond_problem
# - This stackoverflow answer on Multi Inheritance
#   http://stackoverflow.com/q/3277367/1332401
# Python is good to you if you code wisely in it :)

import time
import os

BASE_DIR = os.path.join(os.path.dirname(__file__), '..')


class SatelliteActions(object):
    '''
    Calls ansible playbooks under: 'playbooks/satellite'
    '''

    def __init__(self):
        super(SatelliteActions, self).__init__()

    def add_products(self, extra_vars={}):
        tags = ['add_product']
        runner = self.prepare_runner(os.path.join(BASE_DIR,
                                     'playbooks/satellite/', 'satutils.yaml'),
                                    tasks=tags)
        runner.run()
        print("process stats result: %s" % self.process_stats(runner))

    def all(self, extra_vars={}):
        # extra_vars = {'all': 'true'}
        # runner = self.prepare_runner(os.path.join(BASE_DIR,
        #                              'playbooks/satellite/', 'satutils.yaml'),
        #                             tasks=tags, _extra_vars=extra_vars)
        # runner.run()
        # print("process stats result: %s" % self.process_stats(runner))
        self.backup_satellite()
        self.logger.info("satellite backup CHECK")
        self.upload_manifest()
        self.logger.info("uploaded manifest CHECK")
        self.enable_content()
        self.logger.info("enabled content CHECK")
        self.logger.info("...sleeping for 10 seconds.")
        print("...sleeping for 10 seconds.")
        time.sleep(10)
        self.sync_content()
        self.logger.info("synced content CHECK")
        self.sync_capsule()
        self.logger.info("synced capsules CHECK")

    def backup_satellite(self, extra_vars={}):
        tags = ['backup']
        runner = self.prepare_runner(os.path.join(BASE_DIR,
                                     'playbooks/satellite/', 'satutils.yaml'),
                                    tasks=tags, _extra_vars=extra_vars)
        runner.run()
        print("process stats result: %s" % self.process_stats(runner))

    def check_status(self, extra_vars={}):
        tags = ['katello_check']
        extra_vars = {}
        runner = self.prepare_runner(os.path.join(BASE_DIR,
                                     'playbooks/satellite/', 'satutils.yaml'),
                                    tasks=tags, _extra_vars=extra_vars)
        runner.run()
        print("process stats result: %s" % self.process_stats(runner))

    def content_view_create(self, extra_vars={}):
        tags = ['content_view_create']
        if self.CV_SCALE:
            extra_vars['cv_scale'] = True
            extra_vars['numcv'] = self.CV_SCALE_COUNT.encode('utf-8')
        else:
            extra_vars['cv_scale'] = False
        runner = self.prepare_runner(os.path.join(BASE_DIR,
                                     'playbooks/satellite/', 'satutils.yaml'),
                                    tasks=tags, _extra_vars=extra_vars)
        runner.run()
        print("process stats result: %s" % self.process_stats(runner))

    def content_view_promote(self, extra_vars={}):
        self.logger.debug("This functionality is currently a stub")
        # tags = ['content_view_promote']
        # extra_vars = { }
        # if self.CONCURRENT:
        #     extra_vars['cv_startegy'] = 'conc'
        #     extra_vars['config_name'] = self.TNAME + '-promote-conc'
        # else:
        #     extra_vars['cv_startegy'] = 'seq'
        #     extra_vars['config_name'] = self.TNAME + '-promote-seq'
        #
        # runner = self.prepare_runner(os.path.join(BASE_DIR,
        #                              'playbooks/satellite/', 'satutils.yaml'),
        #                             tasks=tags, _extra_vars=extra_vars)
        # runner.run()
        # print("process stats result: %s" % self.process_stats(runner))

    def content_view_publish(self, extra_vars={}):
        tags = ['content_view_publish']
        if self.CV_SCALE:
            extra_vars['cv_scale'] = True
            extra_vars['num_cv_publish'] = self.CV_PUB_COUNT
            extra_vars['config_name'] = self.TNAME + '-promote-conc'
        else:
            extra_vars['cv_scale'] = False

        runner = self.prepare_runner(os.path.join(BASE_DIR,
                                     'playbooks/satellite/', 'satutils.yaml'),
                                    tasks=tags, _extra_vars=extra_vars)
        runner.run()
        print("process stats result: %s" % self.process_stats(runner))

    def create_life_cycle(self, extra_vars={}):
        tags = ['create_lifecycle']
        runner = self.prepare_runner(os.path.join(BASE_DIR,
                                     'playbooks/satellite/', 'satutils.yaml'),
                                    tasks=tags, _extra_vars=extra_vars)
        runner.run()
        print("process stats result: %s" % self.process_stats(runner))

    def docker_tierdown(self, extra_vars={}):
        runner = self.prepare_runner(os.path.join(BASE_DIR,
                                     'playbooks/satellite/', 'docker-tierdown.yaml'))
        runner.run()
        print("process stats result: %s" % self.process_stats(runner))

    def docker_tierup(self, extra_vars={}):
        runner = self.prepare_runner(os.path.join(BASE_DIR,
                                     'playbooks/satellite/', 'docker-tierup.yaml'))
        runner.run()
        print("process stats result: %s" % self.process_stats(runner))

    def enable_content(self, extra_vars={}):
        tags = ['enable_content']
        runner = self.prepare_runner(os.path.join(BASE_DIR,
                                     'playbooks/satellite/', 'satutils.yaml'),
                                    tasks=tags, _extra_vars=extra_vars)
        runner.run()
        print("process stats result: %s" % self.process_stats(runner))

    def install_capsule(self, extra_vars={}):
        runner = self.prepare_runner(os.path.join(BASE_DIR,
                                     'playbooks/satellite/', 'capsules.yaml'))
        runner.run()
        print("process stats result: %s" % self.process_stats(runner))

    def install_satellite(self, extra_vars={}):
        runner = self.prepare_runner(os.path.join(BASE_DIR,
                                     'playbooks/satellite/', 'installation.yaml'))
        if bool(runner.run()):
            print("Success")
        else:
            print("Failed")

    def install_on_aws(self, extra_vars={}):
        runner = self.prepare_runner(os.path.join(BASE_DIR,
                                     'playbooks/satellite/', 'aws.yaml'))
        runner.run()
        print("process stats result: %s" % self.process_stats(runner))

    def prepare_docker_hosts(self):
        runner = self.prepare_runner(os.path.join(BASE_DIR,
                                     'playbooks/satellite/', 'docker-host.yaml'))
        runner.run()
        # TODO: the last task in docker-host.yaml is to build a
        # docker image. It displays the ansible status "changed"
        # and hence gives out a state that apparently seems failed
        # in the check below, but it isn't. So we need to consider that
        # and log a message accordingly
        # if bool(self.process_stats(runner)):
        #     print("Success")
        # else:
        #     print("Failed")

    def register_content_host(self, extra_vars={}):
        self.logger.debug("This functionality is currently a stub")
        # extra_vars = {'register_content_host': 'true'}
        # if self.CONCURRENT:
        #     extra_vars['cv_startegy'] = 'conc'
        # else:
        #     extra_vars['cv_startegy'] = 'seq'
        # runner = self.prepare_runner(os.path.join(BASE_DIR,
        #                              'playbooks/satellite/', 'satutils.yaml'),
        #                             tasks=tags, _extra_vars=extra_vars)
        # runner.run()
        # print("process stats result: %s" % self.process_stats(runner))

    def remove_capsule(self, extra_vars={}):
        runner = self.prepare_runner(os.path.join(BASE_DIR,
                                     'playbooks/satellite/', 'remove-capsules.yaml'))
        runner.run()
        print("process stats result: %s" % self.process_stats(runner))

    def restore_backup(self, _playbook_path='/home/backup', extra_vars={}):
        tags = ['restore']
        extra_vars = { 'backup_path': _playbook_path }
        runner = self.prepare_runner(os.path.join(BASE_DIR,
                                     'playbooks/satellite/', 'satutils.yaml'),
                                    tasks=tags, _extra_vars=extra_vars)
        runner.run()
        print("process stats result: %s" % self.process_stats(runner))

    def sync_capsule(self, extra_vars={}):
        tags = ['sync_capsule']
        if self.CONCURRENT:
            extra_vars['cv_startegy'] = 'conc'
            extra_vars['config_name'] = self.TNAME
        else:
            extra_vars['cv_startegy'] = 'seq'

        runner = self.prepare_runner(os.path.join(BASE_DIR,
                                     'playbooks/satellite/', 'satutils.yaml'),
                                    tasks=tags, _extra_vars=extra_vars)
        runner.run()
        print("process stats result: %s" % self.process_stats(runner))

    def sync_content(self, extra_vars={}):
        tags = ['sync_content']
        if self.CONCURRENT:
            extra_vars['cv_startegy'] = 'conc'
            extra_vars['config_name'] = self.TNAME + '-sync-repos'
            extra_vars['repo_count'] = self.SAT_REPO_COUNT
        else:
            extra_vars['cv_startegy'] = 'seq'

        runner = self.prepare_runner(os.path.join(BASE_DIR,
                                     'playbooks/satellite/', 'satutils.yaml'),
                                    tasks=tags, _extra_vars=extra_vars)
        runner.run()
        print("process stats result: %s" % self.process_stats(runner))

    def upload_manifest(self, extra_vars={}):
        tags = ['upload_manifest']
        extra_vars = {
            'REPOSERVER': self.content_repo_server,
            'MANIFSET': self.manifest_file
        }
        runner = self.prepare_runner(os.path.join(BASE_DIR,
                                     'playbooks/satellite/', 'satutils.yaml'),
                                    tasks=tags, _extra_vars=extra_vars)
        runner.run()
        print("process stats result: %s" % self.process_stats(runner))

    def run_a_playbook(self, pb_name, extra_vars={}):
        runner = self.prepare_runner(pb_name,
                                    _extra_vars=extra_vars)
        runner.run()
        print("process stats result: %s" % self.process_stats(runner))

class SatelliteAPI(object):
    '''
    '''
    def __init__(self, _args=''):
        super(SatelliteAPI, self).__init__()
        self.args = _args

    def _health_checkup(self):
        self.logger.debug("This functionality is currently a stub")

    def query_process_count(self):
        self.logger.debug("This functionality is currently a stub")

    def query_open_connections(self):
        self.logger.debug("This functionality is currently a stub")


class MonitoringActions(object):
    '''
    Calls ansible playbooks under: 'playbooks/monitoring/'
    '''

    def __init__(self):
        super(MonitoringActions, self).__init__()

    def install_collectd(self, tags):
        extra_vars = { }
        runner = self.prepare_runner(os.path.join(BASE_DIR,
                             'playbooks/monitoring/', 'collectd-generic.yaml'),
                             tasks=tags, _extra_vars=extra_vars)
        runner.run()
        print("process stats result: %s" % self.process_stats(runner))

    def install_elk(self):
        self.logger.debug("This functionality is currently a stub")
        # runner = self.prepare_runner(os.path.join(BASE_DIR,
        #                              'playbooks/monitoring/', 'elk.yaml'))
        # runner.run()
        # print("process stats result: %s" % self.process_stats(runner))

    def install_grafana(self):
        runner = self.prepare_runner(os.path.join(BASE_DIR,
                                     'playbooks/monitoring/', 'grafana.yaml'))

        runner.run()
        print("process stats result: %s" % self.process_stats(runner))

    def install_graphite(self):
        runner = self.prepare_runner(os.path.join(BASE_DIR,
                                     'playbooks/monitoring/', 'graphite.yaml'))
        runner.run()
        print("process stats result: %s" % self.process_stats(runner))

    def prepare_elk_client(self):
        self.logger.debug("This functionality is currently a stub")
        # # filebeat
        # runner = self.prepare_runner(os.path.join(BASE_DIR,
        #                              'playbooks/monitoring/', 'elk-client.yaml'))
        # runner.run()
        # print("process stats result: %s" % self.process_stats(runner))

    def snapshot_dashboard(self, extra_vars={}):
        self.logger.debug("This functionality is currently a stub")
        # if not extra_vars:
        #     # prepare stub
        #     extra_vars = {
        #         "grafana_ip": "1.1.1.1",
        #         "grafana_port": 3000,
        #         "from": 1455649200000,
        #         "to": 1455656400000,
        #         "results_dir": "results/",
        #         "var_cloud": "satellite"
        #     }
        #
        # runner = self.prepare_runner(os.path.join(BASE_DIR,
        #                              'playbooks/monitoring/', 'snapshot_perf_dashboard.yaml'),
        #                              _extra_vars=extra_vars)
        # runner.run()
        # print("process stats result: %s" % self.process_stats(runner))

    def upload_dashboard_grafana(self):
        runner = self.prepare_runner(os.path.join(BASE_DIR,
                                     'playbooks/monitoring/', 'dashboards-generic.yaml'))
        runner.run()
        print("process stats result: %s" % self.process_stats(runner))


class PbenchActions(object):
    '''
    '''
    def __init__(self, _args=''):
        super(PbenchActions, self).__init__()
        self.args = _args

    def setup_pbench(self):
        self.logger.debug("This functionality is currently a stub")

    def cleanup(self):
        self.logger.info("clearing pre-registered pbench toolset")
        self.logger.debug("This functionality is currently a stub")

    def register_config(self):
        self.logger.debug("This functionality is currently a stub")

    def pbench_postprocess(self):
        self.logger.debug("This functionality is currently a stub")
