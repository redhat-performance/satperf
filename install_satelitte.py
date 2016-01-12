#Author Pradeep Kumar Surisetty<psuriset@redhat.com>
#!/usr/bin/python2

import os,re,commands,sys
from urlparse import urljoin

BASE_PATH = os.path.dirname(os.path.abspath(__file__))

def which_release():
    """
    return the release number
    """
    release_no = None
    if os.path.isfile('/etc/redhat-release'):
        vendor = "Redhat"
        str = open('/etc/redhat-release','r')
	release_no = str.readlines()[0].split()[6].split('.')[0]
	print release_no
        return release_no
    else:
        # TODO
        # Handle for other flavours of linux
        return release_no

def yum_setup(release=None, sat_repo_url=None):
    """
    Configure yum repo
    """
    #Repo links

    sat_link = urljoin(sat_repo_url, 
                    "latest-stable-Satellite-6.1-RHEL-" + release + "/compose/Satellite/x86_64/os/")

    #Repo paths   
    sat6_repo = "/etc/yum.repos.d/sat6.repo"
    sat6_capsule_repo = "/etc/yum.repos.d/sat6-capsule.repo"
    sat6_tools_repo = "/etc/yum.repos.d/sat6-tools.repo"

    #yum config
    if os.path.isdir(sat6_repo):
        sys.stdout.write("Repo already configured")
    else:
        repo_fh=open(sat6_repo,'w')
        repo_fh.write('[sat6]\n')
        repo_fh.write('name = Satellite6\n')
        repo_fh.write('baseurl = '+sat_link+'\n')
        repo_fh.write('enabled = 1\n')
        repo_fh.write('gpgcheck = 0\n')
        repo_fh.close()

    installer()

def subscription(release=None, username=None, password=None, pool_id=None):
    """
    Subscription
    """
    print username
    sub_cmd="subscription-manager register --username=%s --password=%s" % (username, password)
    sum_cmd_attach = "subscription-manager attach --pool=%s" % (pool_id)
    yum_utils_cmd="yum install yum-utils.noarch"
    yum_config_cmd = "yum-config-manager --enable rhel-server-rhscl-%s-rpms" %(release)
    sub_mgr_cmd = "subscription-manager repos --enable rhel-server-rhscl-%s-rpms" %(release)

    os.system(sub_cmd)
    #os.system("yum-config-manager --disable rhel-sap-hana-for-rhel-7-server-rpms")
    os.system(sum_cmd_attach)
    os.system(yum_utils_cmd)
    os.system("setenforce 1")
    os.system(yum_config_cmd)
    os.system(sub_mgr_cmd)

def installer():
    """
    install katello
    """
    ket_cmd="katello-installer --foreman-admin-password=changeme"
    os.system("yum install -y katello")
    os.system(ket_cmd)

def main():
    """
    Install setup 
    """
    
    release = which_release()
    
    subscription(release=release, 
                username=os.environ.get("RHN_USERNAME"), 
                password=os.environ.get("RHN_PASSWORD"),
                pool_id=os.environ.get("pool_id"))
    
    yum_setup(release=release,
            sat_repo_url=os.environ.get("SAT_REPO"))
    
    installer()

if __name__ == "__main__":
    main()
