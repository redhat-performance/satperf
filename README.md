# satperf

#satperf: What does it have? 

This project was started to run performance tests on Redhat Satelitte.
satperf needs to be run from Satelitte server. It does the following activities:

 Satelitte installation
 uploads manigfest, updates repo
 concurrently syncs multiple Repositories from Repo Server
 creates lifecycle environments
 creates capsules
 concurrently  syncronizes multiple capsules
 ..etc

 
 Measures time for all while capturing resources using pbench. 
 https://github.com/distributed-system-analysis/pbench

#Note: 
Before Running satperf,update satperf.cfg with details like RHN_USERNAME, 
RHN_PASSWD, pool_id, capsule names etc.

Update PBENCH_REPO and  install pbench using pbench/install_pench.sh on 
required nodes. ./pbench/install_pbensh.sh  

And copy public keys of satelitte server and capsules.
