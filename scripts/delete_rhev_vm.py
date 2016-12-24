#!/usr/bin/env python

from ovirtsdk.api import API
import argparse,sys,re

# parse arguments

parser = argparse.ArgumentParser(description="Script to start RHEV boxes")

parser.add_argument("--url", help="RHEV_URL", required=True)
parser.add_argument("--rhevusername", help="RHEV username", required=True)
parser.add_argument("--rhevpassword", help="RHEV password", required=True)
parser.add_argument("--rhevcafile", help="Path to RHEV ca file, default is /etc/pki/ovirt-engine/ca.pem", default="/etc/pki/ovirt-engine/ca.pem")
parser.add_argument("--vmprefix", help="virtual machine name prefix, this prefix will be used to select machines agaist "
									   "selected action will be executed")
parser.add_argument("--action", help="What action to execute. Action can be:"
									 "start - start machine"
									 "stop - stop machine "
                                                                         "delete - Delete machine"
									 "collect - collect ips/fqdn of machine")
args = parser.parse_args()

url = args.url
rhevusername = args.rhevusername
rhevpassword = args.rhevpassword
rhevcafile = args.rhevcafile
vmprefix = args.vmprefix
action = args.action

# RHEV API
api = API(url=url,username=rhevusername, password=rhevpassword, ca_file=rhevcafile)

# start VMs
def vm_start(vmprefix):
    try:
        vmlist = api.vms.list(max=500)
        for machine in vmlist:
            if api.vms.get(machine.name).status.state != 'up' and machine.name.startswith(vmprefix):
                print ("Starting machine:", machine.name)
                api.vms.get(machine.name).start()
            elif api.vms.get(machine.name).status.state == 'up' and machine.name.startswith(vmprefix):
                print ("Machine:", machine.name , "is already up and running")
    except Exception as e:
        print ("Failed to start Virtual machine", machine, "check it via web interface ", url)

# stop VMs
def vm_stop(vmprefix):
    try:
        vmlist = api.vms.list(max=500)
        for machine in vmlist:
            if api.vms.get(machine.name).status.state == 'up' and machine.name.startswith(vmprefix):
                print ("Stopping machine", machine.name)
                api.vms.get(machine.name).stop()
            elif api.vms.get(machine.name).status.state == 'non_responding' and machine.name.startswith(vmprefix):
                print ("machine", machine.name, "is in nonresponding state, stopping it")
                api.vms.get(machine.name).stop()
    except Exception as e:
        print ("failed to stop Virtual machine", machine, "check it via web interface", url)


# delete VMs
def vm_delete(vmprefix):
	try:
		vmlist = api.vms.list(max=500)
		for machine in vmlist:
			if api.vms.get(machine.name).status.state == 'up' and machine.name.startswith(vmprefix):
				print ("Machine:", machine.name, "is runnning, check web" , url,"running machines will not be deleted - stop them first and run script again")
			elif api.vms.get(machine.name).status.state == 'down' and machine.name.startswith(vmprefix):
				api.vms.get(machine.name).delete()
				print ("Deleted machine", machine.name)
			elif api.vms.get(machine.name).status.state == 'not_responding' and machine.name.startswith(vmprefix):
				print ("Stopping machine", machine.name, "This machine was in notresponding status,stopping it, ... check machine: ", machine.name)
				api.vms.get(machine.name).stop()
	except Exception as e:
		print ("Failed to delete virtual machine", machine.name,"check web:", url)


def vm_collect_ip(vmprefix):
	vmlist = api.vms.list()
#	ipvs=re.compile('^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?).){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$')
	for machine in vmlist:
		info = machine.get_guest_info()
		if machine.name.startswith(vmprefix):
			if info is not None and info.get_fqdn() is not None:
				with open(str(vmprefix)+"fqdn", "a") as myfilefqdn:
					myfilefqdn.write(info.get_fqdn() + "\n")
"""
			if machine.guest_info != None:
				ips = machine.guest_info.get_ips()
				for ip in ips.get_ip():
					ipaddr=ip.get_address()
					if re.search(ipvs,ipaddr):
						with open(str(vmprefix) + "ips", "a") as myfileip:
							myfileip.write(ipaddr + "\n")
"""


if action == "start":
	vm_start(vmprefix)
elif action == "stop":
	vm_stop(vmprefix)
elif action == "delete":
	vm_delete(vmprefix)
elif action == "collect":
	vm_collect_ip(vmprefix)

api.disconnect()
