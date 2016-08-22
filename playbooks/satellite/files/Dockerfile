FROM fedora
MAINTAINER Elvir Kuric <elvirkuric@gmail.com>
RUN dnf install -y openssh-server && dnf clean all
RUN systemctl enable sshd && \
    ssh-keygen -A && \
    echo "root:fedora" | chpasswd

RUN sed -i 's/PermitRootLogin without-password/PermitRootLogin yes/' /etc/ssh/sshd_config
RUN sed 's@session\s*required\s*pam_loginuid.so@session optional pam_loginuid.so@g' -i /etc/pam.d/sshd
WORKDIR /root
EXPOSE 22
USER root
CMD ["/usr/sbin/sshd", "-D"]
