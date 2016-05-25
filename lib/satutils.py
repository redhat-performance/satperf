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


class SatelliteActions(object):
    """
    Calls ansible playbooks under: 'playbooks/satellite'
    """

    def __init__(self):
        super(SatelliteActions, self).__init__()

    def add_products(self):
        extra_vars = {'add_products': 'true'}
        runner = self.prepare_runner('satutils.yaml',
                                    _extra_vars=extra_vars)
        runner.run()
        if bool(self.process_stats(runner)):
            print("Success")
        else:
            print("Failed")

    def all(self):
        extra_vars = {'all': 'true'}
        runner = self.prepare_runner('satutils.yaml',
                                    _extra_vars=extra_vars)
        runner.run()
        if bool(self.process_stats(runner)):
            print("Success")
        else:
            print("Failed")

        # self.backup_satellite()
        # self.logger.info("satellite backup CHECK")
        # self.upload_manifest()
        # self.logger.info("uploaded manifest CHECK")
        # self.enable_content()
        # self.logger.info("enabled content CHECK")
        # self.logger.info("...sleeping for 10 seconds.")
        # print("...sleeping for 10 seconds.")
        # time.sleep(10)
        # self.sync_content()
        # self.logger.info("synced content CHECK")
        # self.sync_capsule()
        # self.logger.info("synced capsules CHECK")

    def backup_satellite(self):
        runner = self.prepare_runner('satutils.yaml')
        runner.run()
        if bool(self.process_stats(runner)):
            print("Success")
        else:
            print("Failed")

    def check_status(self):
        extra_vars = {'katello_check': 'true'}
        runner = self.prepare_runner('satutils.yaml',
                                    _extra_vars=extra_vars)
        runner.run()
        if bool(self.process_stats(runner)):
            print("Success")
        else:
            print("Failed")

    def content_view_create(self):
        extra_vars = {'content_view_create': 'true'}
        if self.CV_SCALE:
            extra_vars['cv_scale'] = 'true'
        else:
            extra_vars['cv_scale'] = 'false'

        runner = self.prepare_runner('satutils.yaml',
                                    _extra_vars=extra_vars)
        runner.run()
        if bool(self.process_stats(runner)):
            print("Success")
        else:
            print("Failed")

    def content_view_promote(self):
        extra_vars = {'content_view_promote': 'true'}
        if self.CONCURRENT:
            extra_vars['cv_startegy'] = 'conc'
        else:
            extra_vars['cv_startegy'] = 'seq'

        runner = self.prepare_runner('satutils.yaml',
                                    _extra_vars=extra_vars)
        runner.run()
        if bool(self.process_stats(runner)):
            print("Success")
        else:
            print("Failed")

    def content_view_publish(self):
        extra_vars = {'content_view_publish': 'true'}
        if self.CV_SCALE:
            extra_vars['cv_scale'] = 'true'
        else:
            extra_vars['cv_scale'] = 'false'

        runner = self.prepare_runner('satutils.yaml',
                                    _extra_vars=extra_vars)
        runner.run()
        if bool(self.process_stats(runner)):
            print("Success")
        else:
            print("Failed")


    def create_life_cycle_env(self):
        extra_vars = {'create_lifecycle': 'true'}
        runner = self.prepare_runner('satutils.yaml',
                                    _extra_vars=extra_vars)
        runner.run()
        if bool(self.process_stats(runner)):
            print("Success")
        else:
            print("Failed")

    def docker_tierdown(self):
        runner = self.prepare_runner('docker-tierdown.yaml')
        runner.run()
        if bool(self.process_stats(runner)):
            print("Success")
        else:
            print("Failed")

    def docker_tierup(self):
        runner = self.prepare_runner('docker-tierup.yaml')
        runner.run()
        if bool(self.process_stats(runner)):
            print("Success")
        else:
            print("Failed")

    def enable_content(self):
        extra_vars = {'enable_content': 'true'}
        runner = self.prepare_runner('satutils.yaml',
                                    _extra_vars=extra_vars)
        runner.run()
        if bool(self.process_stats(runner)):
            print("Success")
        else:
            print("Failed")

    def install_capsule(self):
        runner = self.prepare_runner('capsules.yaml')
        runner.run()
        if bool(self.process_stats(runner)):
            print("Success")
        else:
            print("Failed")

    def install_satellite(self):
        runner = self.prepare_runner('installation.yaml')
        if bool(runner.run()):
            print("Success")
        else:
            print("Failed")

    def install_on_aws(self):
        runner = self.prepare_runner('aws.yaml')
        runner.run()
        if bool(self.process_stats(runner)):
            print("Success")
        else:
            print("Failed")

    def prepare_docker_hosts(self):
        runner = self.prepare_runner('docker-host.yaml')
        runner.run()
        if bool(self.process_stats(runner)):
            print("Success")
        else:
            print("Failed")

    def register_content_host(self):
        extra_vars = {'register_content_host': 'true'}
        if self.CONCURRENT:
            extra_vars['cv_startegy'] = 'conc'
        else:
            extra_vars['cv_startegy'] = 'seq'

        runner = self.prepare_runner('satutils.yaml',
                                    _extra_vars=extra_vars)
        runner.run()
        if bool(self.process_stats(runner)):
            print("Success")
        else:
            print("Failed")

    def remove_capsule(self):
        runner = self.prepare_runner('remove-capsules.yaml')
        runner.run()
        if bool(self.process_stats(runner)):
            print("Success")
        else:
            print("Failed")

    def restore_backup(self, _playbook_path='/home/backup'):
        extra_vars = {'backup': 'true',
                'backup_path': _playbook_path }
        runner = self.prepare_runner('satutils.yaml',
                                    _extra_vars=extra_vars)
        runner.run()
        if bool(self.process_stats(runner)):
            print("Success")
        else:
            print("Failed")

    def sync_capsule(self):
        extra_vars = {'sync_capsule': 'true'}
        if self.CONCURRENT:
            extra_vars['cv_startegy'] = 'conc'
        else:
            extra_vars['cv_startegy'] = 'seq'

        runner = self.prepare_runner('satutils.yaml',
                                    _extra_vars=extra_vars)
        runner.run()
        if bool(self.process_stats(runner)):
            print("Success")
        else:
            print("Failed")

    def sync_content(self):
        extra_vars = {'sync_content': 'true'}
        if self.CONCURRENT:
            extra_vars['cv_startegy'] = 'conc'
        else:
            extra_vars['cv_startegy'] = 'seq'

        runner = self.prepare_runner('satutils.yaml',
                                    _extra_vars=extra_vars)
        runner.run()
        if bool(self.process_stats(runner)):
            print("Success")
        else:
            print("Failed")

    def upload_manifest(self):
        extra_vars = {'upload_manifest': 'true'}
        runner = self.prepare_runner('satutils.yaml',
                                    _extra_vars=extra_vars)
        runner.run()
        if bool(self.process_stats(runner)):
            print("Success")
        else:
            print("Failed")


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
    """
    Calls ansible playbooks under: 'monitoring/satellite'
    """

    def __init__(self):
        super(MonitoringActions, self).__init__()

    def install_collectd(self):
        runner = self.prepare_runner('collectd-generic.yaml')
        runner.run()
        if bool(self.process_stats(runner)):
            print("Success")
        else:
            print("Failed")

    def install_elk(self):
        runner = self.prepare_runner('elk.yaml')
        runner.run()
        if bool(self.process_stats(runner)):
            print("Success")
        else:
            print("Failed")

    def install_grafana(self):
        runner = self.prepare_runner('grafana.yaml')
        runner.run()
        if bool(self.process_stats(runner)):
            print("Success")
        else:
            print("Failed")

    def install_graphite(self):
        runner = self.prepare_runner('graphite.yaml')
        runner.run()
        if bool(self.process_stats(runner)):
            print("Success")
        else:
            print("Failed")

    def prepare_elk_client(self):
        # filebeat
        runner = self.prepare_runner('elk-client.yaml')
        runner.run()
        if bool(self.process_stats(runner)):
            print("Success")
        else:
            print("Failed")

    def snapshot_dashboard(self, extra_vars={}):
        if not extra_vars:
            # prepare stub
            extra_vars = {
                "grafana_ip": "1.1.1.1",
                "grafana_port": 3000,
                "from": 1455649200000,
                "to": 1455656400000,
                "results_dir": "results/",
                "var_cloud": "satellite"
            }

        runner = self.prepare_runner('snapshot_perf_dashboard.yaml',
                                     _extra_vars=extra_vars)
        runner.run()
        if bool(self.process_stats(runner)):
            print("Success")
        else:
            print("Failed")

    def upload_dashboards_grafana(self):
        runner = self.prepare_runner('dashboards-generic.yaml')
        runner.run()
        if bool(self.process_stats(runner)):
            print("Success")
        else:
            print("Failed")


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
