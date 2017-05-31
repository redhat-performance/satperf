#!/bin/bash

set -x
set -e

name=$( grep '^Name:' rel-eng/satellite-performance.spec | sed 's/^Name:\s*\([a-z-]\+\)\s*$/\1/' )
version=$( grep '^Version:' rel-eng/satellite-performance.spec | sed 's/^Version:\s*\([0-9.]\+\)\s*$/\1/' )
directory="$name-$version"
archive="$directory.tar.gz"

echo $name $version

rm -rf /tmp/$directory
mkdir /tmp/$directory
./cleanup

cp README.md /tmp/$directory/
cp LICENSE /tmp/$directory/
cp cleanup /tmp/$directory/
cp -r playbooks /tmp/$directory/
mkdir /tmp/$directory/conf/
cp conf/hosts.ini /tmp/$directory/conf/
cp conf/satperf.yaml /tmp/$directory/conf/

tar -czf $archive -C /tmp $directory
rm -rf /tmp/$directory

cp $archive ~/rpmbuild/SOURCES/
rm $archive
cp rel-eng/satellite-performance.spec ~/rpmbuild/SPECS/

rpmbuild -ba ~/rpmbuild/SPECS/satellite-performance.spec
