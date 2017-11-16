#!/usr/bin/env python
# -*- coding: UTF-8 -*-

# This script is intended to build lots of packages for installation into
# docker containers so they have bigger package manifest. Files in packages
# have minimal size, but metadata-vise should be comparable with normal
# packages.
#
# Usage:
#
# Run it and then copy it somewhere containers can reach it:
#
#   scp $( find . -name \*.x86_64.rpm ) root@<...>:/var/www/html/pub/<...>
#
# Then create repo from these and prepare repofile and add womething like
# this into Dockerfile:
#
#   RUN curl http://<...>/pub/lots_of_packages/lots_of_packages.repo -o /etc/yum.repos.d/lots_of_packages.repo \
#       && yum -y install foo \* --disablerepo=\* --enablerepo=lots_of_packages \
#       && rm -f /etc/yum.repos.d/lots_of_packages.repo \
#       && rm -rf /var/cache/yum/*

import rpmfluff

# Get some stats to decide on numbers:
#   rpm -ql $( rpm -qa | sort -R | head -n 100 ) | wc -l
#   rpm -q --provides $( rpm -qa | sort -R | head -n 100 ) | wc -l
#   rpm -q --requires $( rpm -qa | sort -R | head -n 100 ) | wc -l
#   rpm -qa --qf "%{SOURCERPM}\n" | sort -u | wc -l; rpm -qa | wc -l

PACKAGES = 1000
SUBPACKAGES = 1
CHANGELOGS = 50
FILES = 100 * SUBPACKAGES   # we can not have files in subpackages in rpmfluff, so move the payload into main package
PROVIDES = 10
REQUIRES = 20
VERSION = "0.1"

for p in range(PACKAGES):
    foo = rpmfluff.SimpleRpmBuild("foo%s" % p, VERSION, str(CHANGELOGS))
    foo.add_summary('This is summary for foo%s' % p)
    foo.add_description('This is descriptive description for foo%s' % p)
    for c in range(CHANGELOGS):
        foo.add_changelog_entry('This is entry %s for package foo%s' % (c, p), VERSION, str(c))
    for f in range(FILES):
        foo.add_simple_payload_file_random()
    for d in range(PROVIDES):
        foo.add_provides("foo%s_provided%s" % (p, d))
    for s in range(SUBPACKAGES):
        for d in range(PROVIDES):
            foo.add_requires("foo%s_sub%s_required%s" % (p, s, d))
    for d in range(REQUIRES - (SUBPACKAGES * PROVIDES)):
        foo.add_requires("/bin/bash")
    for s in range(SUBPACKAGES):
        sub = foo.add_subpackage('sub%s' % s)
        sub.add_summary('This is summary for foo%s-sub%s' % (p, s))
        sub.add_description('This is descriptive description for foo%s-sub%s' % (p, s))
        for d in range(PROVIDES):
            sub.add_provides("foo%s_sub%s_required%s" % (p, s, d))
            sub.add_requires("foo%s_provided%s" % (p, d))
    foo.make()
