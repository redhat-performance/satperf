#!/bin/bash

set -x
set -e

name=$( grep '^Name:' rel-eng/satellite-performance.spec | sed 's/^Name:\s*\([a-z-]\+\)\s*$/\1/' )
version=$( grep '^Version:' rel-eng/satellite-performance.spec | sed 's/^Version:\s*\([0-9a-z.]\+\)\s*$/\1/' )
directory="$name-$version"
archive="$directory.tar.gz"

if [ "$version" = 'master' ]; then
  echo "ERROR: Make sure you are in release branch and update version number in rel-eng/satellite-performance.spec first" >&2
  exit 1
fi

# Prepare directory
rm -rf /tmp/$directory
mkdir /tmp/$directory

# Copy content to the directory
./cleanup
cp -r * /tmp/$directory/

# Create tarball
tar -czf $archive -C /tmp $directory
rm -rf /tmp/$directory

# Put files to rpmbuild directories
cp $archive ~/rpmbuild/SOURCES/
rm $archive
cp rel-eng/satellite-performance.spec ~/rpmbuild/SPECS/

# Build rpm
rpmbuild -ba ~/rpmbuild/SPECS/satellite-performance.spec
