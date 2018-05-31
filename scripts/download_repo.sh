#!/bin/bash

function download_cdn() {
    repo=$1
    base=$( echo $repo | sed 's|^\(.*\)/content/.*$|\1|' )
    path=$( echo $repo | sed 's|^.*/\(content/.*\)$|\1|' | sed 's|\(^/\|/$\)||g' )
    mkdir -p $path/repodata
    cwd=$( pwd )

    # Download treeinfo files for the tree
    loop_path=$path
    while true; do
        wget --no-verbose --no-check-certificate $base/$loop_path/listing -O $loop_path/listing
        [ "$loop_path" = '.' ] && break
        loop_path=$( dirname $loop_path )
    done

    # Download repodata
    cd $cwd
    cd $path/repodata
    pwd
    wget --no-verbose --no-check-certificate $repo/repodata/productid
    wget --no-verbose --no-check-certificate $repo/repodata/repomd.xml
    for f in $( curl $repo/repodata/repomd.xml | grep 'location href=' | cut -d '"' -f 2 ); do
        wget --no-verbose --no-check-certificate $repo/$f
    done
    cd $cwd
}

# Download repodata
cd /var/www/html/pub/
download_cdn http://cdn.stage.redhat.com/content/dist/rhel/server/6/6.5/x86_64/os/
download_cdn http://cdn.stage.redhat.com/content/dist/rhel/server/7/7.5/x86_64/optional/os/
download_cdn http://cdn.stage.redhat.com/content/dist/rhel/server/7/7.5/x86_64/os/

# Download packages
cd /var/www/html/pub/
wget -c -r -l 1 --accept rpm http://cdn.stage.redhat.com/content/dist/rhel/server/7/7.5/x86_64/os/Packages/
mkdir content/dist/rhel/server/7/7.5/x86_64/os/Packages
mv cdn.stage.redhat.com/content/dist/rhel/server/7/7.5/x86_64/os/Packages/*.rpm content/dist/rhel/server/7/7.5/x86_64/os/Packages/
rm -rf cdn.stage.redhat.com/

## Enable it on Satellite side
#hammer -u admin -p changeme organization add-location --name "Default Organization" --location "Default Location"
#hammer -u admin -p changeme organization update --name "Default Organization" --redhat-repository-url http://localhost/pub/
