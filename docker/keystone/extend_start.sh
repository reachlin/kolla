#!/bin/bash

if [[ "${KOLLA_BASE_DISTRO}" == "ubuntu" || \
        "${KOLLA_BASE_DISTRO}" == "debian" ]]; then
    # Loading Apache2 ENV variables
    source /etc/apache2/envvars
    APACHE_DIR="apache2"
else
    APACHE_DIR="httpd"
fi

# NOTE(pbourke): httpd will not clean up after itself in some cases which
# results in the container not being able to restart. Unconfirmed if this
# happens on Ubuntu. (bug #1489676)
if [[ "${KOLLA_BASE_DISTRO}" =~ fedora|centos|oraclelinux|rhel ]]; then
    rm -rf /var/run/httpd/* /run/httpd/* /tmp/httpd*
fi

# Create log dir for Keystone logs
KEYSTONE_LOG_DIR="/var/log/kolla/keystone"
if [[ ! -d "${KEYSTONE_LOG_DIR}" ]]; then
    mkdir -p ${KEYSTONE_LOG_DIR}
fi
if [[ $(stat -c %U:%G ${KEYSTONE_LOG_DIR}) != "keystone:kolla" ]]; then
    chown keystone:kolla ${KEYSTONE_LOG_DIR}
fi
if [[ $(stat -c %a ${KEYSTONE_LOG_DIR}) != "755" ]]; then
    chmod 755 ${KEYSTONE_LOG_DIR}
fi

# Create log dir for Apache logs
APACHE_LOG_DIR="/var/log/kolla/${APACHE_DIR}"
if [[ ! -d "${APACHE_LOG_DIR}" ]]; then
    mkdir -p ${APACHE_LOG_DIR}
fi
if [[ $(stat -c %a ${APACHE_LOG_DIR}) != "755" ]]; then
    chmod 755 ${APACHE_LOG_DIR}
fi

# Bootstrap and exit if KOLLA_BOOTSTRAP variable is set. This catches all cases
# of the KOLLA_BOOTSTRAP variable being set, including empty.
if [[ "${!KOLLA_BOOTSTRAP[@]}" ]]; then
    sudo -H -u keystone keystone-manage db_sync
    exit 0
fi

ARGS="-DFOREGROUND"
