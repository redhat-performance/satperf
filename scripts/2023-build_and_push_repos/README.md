Build and push repositories
===========================

For some experiment we needed lots of publically accessible fake repositories.

We used rpmfluff library to generate RPMs (see `script.py`) and run it in the
loop and uploaded final repository to IBM Cloud component storage bucket (see
`script.sh`). For 10k repos it was running multiple days, so we re-logged on
every iteration even if that was unnecessary.

For possible improvements some paralelisation would be nice, but this was just
one shot thing.
