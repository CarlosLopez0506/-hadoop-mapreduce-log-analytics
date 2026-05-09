FROM apache/hadoop:3.4.1
USER root
# apache/hadoop:3.4.1 runs on CentOS 7, which reached EOL; vault holds the archived repos
RUN sed -i \
        -e 's/mirrorlist=/#mirrorlist=/g' \
        -e 's|#baseurl=http://mirror.centos.org|baseurl=https://vault.centos.org|g' \
        /etc/yum.repos.d/CentOS-*.repo && \
    yum install -y python3 && \
    yum clean all
USER hadoop
