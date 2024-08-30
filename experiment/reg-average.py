#!/usr/bin/env python3
# -*- coding: UTF-8 -*-

import argparse
import datetime
import logging
import re
import sys


def parse_time(time_str):
    try:
        time_obj = datetime.datetime.strptime(time_str, '%Y-%m-%d %H:%M:%S.%f')
    except ValueError:
        time_obj = datetime.datetime.strptime(time_str, '%Y-%m-%d %H:%M:%S')

    return time_obj.replace(tzinfo=datetime.timezone.utc)


parser = argparse.ArgumentParser(description='Compute average from log')
parser.add_argument('matcher',
                    help='String to identify log file lines with timestamps')
parser.add_argument('log_file', type=argparse.FileType('r'),
                    help='Log file to process')
parser.add_argument('-d', '--debug', action='store_true',
                    help='Show debug output')

args = parser.parse_args()

if args.debug:
    logging.basicConfig(level=logging.DEBUG)

logging.debug('Args: %s' % args)

total = 0.0
count = 0
start_min = None
end_max = None

for line in args.log_file:
    if re.match('.*"%s .*' % args.matcher, line):
        logging.debug("Processing line %d: %s" % (count, line.strip()))
        m = re.match('^.*"%s (?P<start>[0-9:. -]+) to (?P<end>[0-9:. -]+) taking (?P<duration>[0-9.]+) seconds".*$' % args.matcher, line)

        start = parse_time(m.group('start'))
        end = parse_time(m.group('end'))
        duration = m.group('duration')
        logging.debug("Parsed start, end, duration times on line %d: %s, %s, %s" % (count, start, end, duration))

        if start_min is None or start < start_min:
            start_min = start
        if end_max is None or end > end_max:
            end_max = end
        count += 1
        total += float(duration)

if count == 0:
    logging.error("No matcher %s found in log %s" % (args.matcher, args.log_file.name))
    sys.exit(1)
else:
    print("min in %s: %s" % (args.log_file.name, start_min.timestamp()))
    print("max in %s: %s" % (args.log_file.name, end_max.timestamp()))
    print("%s in %s: %f / %d = %f" %(args.matcher, args.log_file.name, total, count, total / count))
