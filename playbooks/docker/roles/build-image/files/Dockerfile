FROM registry.access.redhat.com/rhel7/rhel-tools
MAINTAINER jeder <jeder@redhat.com>
RUN yum --disablerepo='*' --enablerepo='rhel-7-server-rpms' install -y openssh-server hostname && yum clean all
RUN sed -i 's/PermitRootLogin without-password/PermitRootLogin yes/' /etc/ssh/sshd_config
RUN sed 's@session\s*required\s*pam_loginuid.so@session optional pam_loginuid.so@g' -i /etc/pam.d/sshd
RUN mkdir /root/.ssh && chmod 700 /root/.ssh && touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
RUN echo 'ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEA57NxnEo8KnrBYRrWjgS8eSZBKiUFBbP4GGbC1M1Kxo+494T2+y3uuihK0Ey5n824ch2OafK7m/TnByIC9pQ3VuAi/ggiOfja2gvZ/GtTedE3ct0jVbGbM/98MS0GV1NoIZRqX6e44JMDqID+ngwQutPyTgxbJ/PL2jVUrjP6sOMEJqgSEbQ9a3s+oM3O0vMTLp7E0PtgKQo0bKRoKFEn5mUxiQ2gmwg/dPqOb2/VpBAKCozsE2illszzyP/KC1gq0VkgMqIZspUsXRqvDDbnaSkCc8/AwA0yBAPBMAjtuk5UZvpioHSh2X0ShcgHtYocZiQIxiSvDzvxdYkFBztu6w== perf-team-shared-key' >>/root/.ssh/authorized_keys
RUN echo "root:redhat" | chpasswd
RUN systemctl enable sshd.service; for s in pmcd.service pmlogger.service postfix.service abrtd.service crond.service polkit.service lvm2-lvmetad.socket; do systemctl disable $s; done; exit 0
WORKDIR /root
EXPOSE 22
USER root
STOPSIGNAL SIGRTMIN+3
CMD [ "/sbin/init" ]
