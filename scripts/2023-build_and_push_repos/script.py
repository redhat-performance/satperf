#!/usr/bin/env python
# -*- coding: UTF-8 -*-

# This script is intended to build lots of packages for installation into
# docker containers so they have bigger package manifest. Files in packages
# have minimal size, but metadata-vise should be comparable with normal
# packages.
#
# Requirements:
#
# You need rpmfluff python library installed (Fedora have package in repos)
# or just download rpmfluff.py from https://pagure.io/rpmfluff
#
# Usage:
#
# Run it and then copy it somewhere containers can reach it:
#
#   scp $( find . -name /tmp/\*.x86_64.rpm ) root@<...>:/var/www/html/pub/<...>
#
# Then create repo from these and prepare repofile and add womething like
# this into Dockerfile:
#
#   RUN curl http://<...>/pub/lots_of_packages/lots_of_packages.repo -o /etc/yum.repos.d/lots_of_packages.repo \
#       && yum -y install foo \* --disablerepo=\* --enablerepo=lots_of_packages \
#       && rm -f /etc/yum.repos.d/lots_of_packages.repo \
#       && rm -rf /var/cache/yum/*

import os, sys, shutil

import rpmfluff

# Get some stats to decide on numbers:
#   rpm -ql $( rpm -qa | sort -R | head -n 100 ) | wc -l
#   rpm -q --provides $( rpm -qa | sort -R | head -n 100 ) | wc -l
#   rpm -q --requires $( rpm -qa | sort -R | head -n 100 ) | wc -l
#   rpm -qa --qf "%{SOURCERPM}\n" | sort -u | wc -l; rpm -qa | wc -l

REPO_NAME = 'repo'
REPOS = 1000
NAME = 'foo'
PACKAGES = 50
SUBPACKAGES = 1
CHANGELOGS = 50
FILES = 100 * SUBPACKAGES   # we can not have files in subpackages in rpmfluff, so move the payload into main package
PROVIDES = 10
REQUIRES = 20
VERSION = "0.1"


for r in [int(sys.argv[1])]:
    repo = "%s%s" % (REPO_NAME, r)
    if not os.path.exists(repo):
        os.makedirs(repo)
    for p in range(PACKAGES):
        name = "%s%s-%s" % (NAME, p, repo)
        foo = rpmfluff.SimpleRpmBuild(name, VERSION, str(CHANGELOGS))
        foo.add_summary('This is summary for %s' % name)
        foo.add_description('This is descriptive description for %s' % name)
        for c in range(CHANGELOGS):
            foo.add_changelog_entry('This is entry %s for package %s' % (c, name), VERSION, str(c))
        for f in range(FILES):
            foo.add_simple_payload_file_random()
        for d in range(PROVIDES):
            foo.add_provides("%s_provided%s" % (name, d))
        for s in range(SUBPACKAGES):
            for d in range(PROVIDES):
                foo.add_requires("%s_sub%s_required%s" % (name, s, d))
        for d in range(REQUIRES - (SUBPACKAGES * PROVIDES)):
            foo.add_requires("/bin/bash")
        for s in range(SUBPACKAGES):
            sub = foo.add_subpackage('sub%s' % s)
            sub.add_summary('This is summary for %s-sub%s' % (name, s))
            sub.add_description('This is descriptive description for %s-sub%s' % (name, s))
            for d in range(PROVIDES):
                sub.add_provides("%s_sub%s_required%s" % (name, s, d))
                sub.add_requires("%s_provided%s" % (name, d))
        foo.make()
        for sub in foo.get_subpackage_names():
            rpm_file = foo.get_built_rpm(arch='x86_64', name=sub)
            target = os.path.join(repo, os.path.basename(rpm_file))
            shutil.move(rpm_file, target)
        foo.clean()
    print("Repo %s done" % repo)
