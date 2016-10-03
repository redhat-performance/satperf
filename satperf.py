#!/usr/bin/env python

import os
import sys
import yaml
import signal
import logging
from utils.conf import satperf as config_general
from argparse import RawTextHelpFormatter, \
                ArgumentParser
from lib.satellite import SatelliteCore, time
from pykwalify import core as pykwalify_core
from pykwalify import errors as pykwalify_errors
from logging.handlers import RotatingFileHandler

# _config_file_general = 'conf/satperf.conf'

_logger = logging.getLogger(__name__)

parser = ArgumentParser(formatter_class=RawTextHelpFormatter,
                        description="""Satellite Performance ToolKit""")

BASE_DIR = os.path.join(os.path.dirname(__file__), '..')

def signal_handler(event, frame):
    print("\nKill signal (%s) detected. Stopping satperf.." % event)
    if event == signal.SIGINT:
        sys.exit(130) # 130 is Ctrl-C for bash
    # TODO: maybe add more signal handlers ?
    # sys.exit(1)

def _satperf_usage():
    parser.add_argument("-a", "--all", action='store_true',
        help="Run all jobs in sequence")
    parser.add_argument("-b", "--sat-backup", action='store_true',
        help="Take satelitte server backup to restore further")
    parser.add_argument("-c", "--create-life-cycle", action='store_true',
        help="Create life cycle environments")
    parser.add_argument("-d", "--add-product", action='store_true',
        help="Adding products")
    parser.add_argument("-e", "--enable-content", action='store_true',
        help="Enable repos")
    # parser.add_argument("-f", "--snapshot-dashboard", action='store_true',
    #     help="Snapshot current Grafana Dashboard")
    parser.add_argument("-g", "--register-content-hosts", action='store_true',
        help="Register content hosts (concurrent or sequential)")
    parser.add_argument("-i", "--upload-dashboard-grafana", action='store_true',
        help="Upload dashboard for Satellite (from template) to Grafana")
    parser.add_argument("-l", "--sync-capsule", action='store_true',
        help="Sync capsule (concurrent or sequential)")
    parser.add_argument("-m", "--setup-monitoring", action='store_true',
        help="Setup one/all of: Graphite, Grafana, Collectd, ELK")
    parser.add_argument("-n", "--resync-content", action='store_true',
        help="Resync content (concurrent or sequential) " + \
                                "from repo server to satelitte server")
    parser.add_argument("-p", "--content-view-publish", action='store_true',
        help="Publish content views")
    parser.add_argument("-r", "--sat-restore", action='store_true',
        help="Restore from backup")
    parser.add_argument("-s", "--setup", action='store_true',
        help="Setup Satellite Server, Capsules and Docker hosts")
    parser.add_argument("-t", "--content-view-create", action='store_true',
        help="Create content view and add repos")
    parser.add_argument("-u", "--upload", action='store_true',
        help="Upload manifest")
    parser.add_argument("-w", "--remove-capsule", action='store_true',
        help="Uninstall capsule")
    # parser.add_argument("-x", "--content-view-promote", action='store_true',
    #     help="Promote content view")
    parser.add_argument("-y", "--sync-content", action='store_true',
        help="Sync content (concurrent or sequential) " + \
                                "from repo server to satelitte server")
    parser.add_argument("-z", "--run-playbook", action='store',
        help="Run a playbook from playbooks/satellite/ not listed in satperf")

def main(config_general):
    try:
        nargs = parser.parse_args()

        if not sys.argv[1:]:
          quit("No arguments supplied. Refer to --help.")

        SatCore = SatelliteCore(_conf=config_general,
                                _logger=_logger)
        SatCore.init_actions(nargs)

    except Exception as E:
        # raise
        msg = "ERROR: %s\nUnable to execute. Refer to --help. I Quit!"%(E)
        quit(msg)

if __name__ == '__main__':
    signal.signal(signal.SIGINT, signal_handler)
    # config_general = _load_config(_config_file_general)
    FNAME = config_general["satperf_log_file"]
    FSIZE = int(config_general["satperf_log_file_size"])

    try:
        if not os.path.exists(os.path.dirname(FNAME)):
            os.makedirs(os.path.dirname(FNAME))
    except PermissionError:
        quit("[Permission Denied] during creation of log filepath: %s" % FNAME)
    except Exception as E:
        quit("Error: [%s] - Couldn't create log filepath: %s" % FNAME)

    FMT = "[%(asctime)s] [%(levelname)s ] " + \
          "[%(filename)s:%(lineno)d:%(funcName)s()] - %(message)s"

    formatter = logging.Formatter(FMT)
    handler = RotatingFileHandler(FNAME, maxBytes=FSIZE, backupCount=1)
    handler.setFormatter(formatter)
    _logger.root.level = logging.DEBUG
    _logger.addHandler(handler)

    _satperf_usage()

    print("Storing logs to file: %s" % FNAME)

    sys.exit(main(config_general))
