#!/usr/bin/env bash
#
# Bootstrap script to configure all nodes.
#

VM=$1
MODE=$2
KOLLA_PATH=$3

export http_proxy=
export https_proxy=

if [ "$MODE" = 'aio' ]; then
    # Run registry on port 4000 since it may collide with keystone when doing AIO
    REGISTRY_PORT=4000
    SUPPORT_NODE=operator
else
    REGISTRY_PORT=5000
    SUPPORT_NODE=support01
fi
REGISTRY=operator.local:${REGISTRY_PORT}
ADMIN_PROTOCOL="http"

# Install common packages and do some prepwork.
function prep_work {
    systemctl stop firewalld
    systemctl disable firewalld

    # This removes the fqdn from /etc/hosts's 127.0.0.1. This name.local will
    # resolve to the public IP instead of localhost.
    sed -i -r "s/^(127\.0\.0\.1\s+)(.*) `hostname` (.+)/\1 \3/" /etc/hosts

    yum install -y epel-release
    rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-EPEL-7
    yum install -y MySQL-python vim-enhanced python-pip python-devel gcc openssl-devel libffi-devel libxml2-devel libxslt-devel
    yum clean all
    pip install --upgrade docker-py
}

# Install and configure a quick&dirty docker daemon.
function install_docker {
    # Allow for an externally supplied docker binary.
    if [[ -f "/data/docker" ]]; then
        cp /vagrant/docker /usr/bin/docker
        chmod +x /usr/bin/docker
    else
        cat >/etc/yum.repos.d/docker.repo <<-EOF
[dockerrepo]
name=Docker Repository
baseurl=https://yum.dockerproject.org/repo/main/centos/7
enabled=1
gpgcheck=1
gpgkey=https://yum.dockerproject.org/gpg
EOF
        # Also upgrade device-mapper here because of:
        # https://github.com/docker/docker/issues/12108
        # Upgrade lvm2 to get device-mapper installed
        yum install -y docker-engine lvm2 device-mapper

        # Despite it shipping with /etc/sysconfig/docker, Docker is not configured to
        # load it from it's service file.
        sed -i -r "s|(ExecStart)=(.+)|\1=/usr/bin/docker daemon --insecure-registry ${REGISTRY} --registry-mirror=http://${REGISTRY}|" /usr/lib/systemd/system/docker.service
        sed -i 's|^MountFlags=.*|MountFlags=shared|' /usr/lib/systemd/system/docker.service

        systemctl daemon-reload
        systemctl enable docker
        systemctl start docker
    fi

    usermod -aG docker vagrant
}

function configure_kolla {
    # Use local docker registry
    sed -i -r "s,^[# ]*namespace *=.+$,namespace = ${REGISTRY}/lokolla," /etc/kolla/kolla-build.conf
    sed -i -r "s,^[# ]*push *=.+$,push = True," /etc/kolla/kolla-build.conf
    sed -i -r "s,^[# ]*docker_registry:.+$,docker_registry: \"${REGISTRY}\"," /etc/kolla/globals.yml
    sed -i -r "s,^[# ]*docker_namespace:.+$,docker_namespace: \"lokolla\"," /etc/kolla/globals.yml
    sed -i -r "s,^[# ]*docker_insecure_registry:.+$,docker_insecure_registry: \"True\"," /etc/kolla/globals.yml
    # Set network interfaces
    sed -i -r "s,^[# ]*network_interface:.+$,network_interface: \"eth1\"," /etc/kolla/globals.yml
    sed -i -r "s,^[# ]*neutron_external_interface:.+$,neutron_external_interface: \"eth2\"," /etc/kolla/globals.yml
}

# Configure the operator node and install some additional packages.
function configure_operator {
    yum install -y git mariadb && yum clean all
    pip install --upgrade "ansible<2" python-openstackclient python-neutronclient tox

    pip install ~vagrant/kolla

    # Note: this trickery requires a patched docker binary.
    if [[ "$http_proxy" = "" ]]; then
        su - vagrant sh -c "echo BUILDFLAGS=\\\"--build-env=http_proxy=$http_proxy --build-env=https_proxy=$https_proxy\\\" > ~/kolla/.buildconf"
    fi

    # Set selinux to permissive
    sed -i -r "s,^SELINUX=.+$,SELINUX=permissive," /etc/selinux/config
    setenforce permissive

    cp -r ~vagrant/kolla/etc/kolla/ /etc/kolla
    oslo-config-generator --config-file \
        ~vagrant/kolla/etc/oslo-config-generator/kolla-build.conf \
        --output-file /etc/kolla/kolla-build.conf
    mkdir -p /usr/share/kolla
    chown -R vagrant: /etc/kolla /usr/share/kolla

    configure_kolla

    # Make sure Ansible uses scp.
    cat > ~vagrant/.ansible.cfg <<EOF
[defaults]
forks=100

[ssh_connection]
scp_if_ssh=True
EOF
    chown vagrant: ~vagrant/.ansible.cfg

    # The openrc file.
    cat > ~vagrant/openrc <<EOF
export OS_AUTH_URL="${ADMIN_PROTOCOL}://${SUPPORT_NODE}:35357/v3"
export OS_USERNAME=admin
export OS_PASSWORD=password
export OS_TENANT_NAME=admin
export OS_VOLUME_API_VERSION=3
export OS_USER_DOMAIN_ID=default
EOF
    chown vagrant: ~vagrant/openrc

    mkdir -p /etc/kolla/config/nova/
    cat > /etc/kolla/config/nova/nova-compute.conf <<EOF
[libvirt]
virt_type=qemu
EOF


    # Launch a local registry (and mirror) to speed up pulling images.
    if [[ ! $(docker ps -a -q -f name=registry) ]]; then
        docker run -d \
            --name registry \
            --restart=always \
            -p ${REGISTRY_PORT}:5000 \
            -e STANDALONE=True \
            -e MIRROR_SOURCE=https://registry-1.docker.io \
            -e MIRROR_SOURCE_INDEX=https://index.docker.io \
            -e STORAGE_PATH=/var/lib/registry \
            -v /data/host/registry-storage:/var/lib/registry \
            registry:2
    fi
}

prep_work
install_docker

if [[ "$VM" = "operator" ]]; then
    configure_operator
fi
