#!/bin/bash

# This script runs on the compute node of the cluster upon first boot before
# any other cluster/Slurm setup. It initializes the following:
#  - setting up additional SSH users

# General setup
dnf install nano

# Create users
echo "Creating users..."
USERS_GID="$(getent group users | cut -d : -f 3)"
while read -r NEW_UID NEW_USER; do
    useradd -d "/home/$NEW_USER" -M -N -g "$USERS_GID" -u "$NEW_UID" "$NEW_USER"
done < "/opt/parallelcluster/shared/users.txt"

# Set up node exporter
echo "Setting up node exporter..."

cat >/etc/yum.repos.d/prometheus.repo <<'EOF'
[prometheus]
name=prometheus
baseurl=https://packagecloud.io/prometheus-rpm/release/el/$releasever/$basearch
repo_gpgcheck=1
enabled=1
gpgkey=https://packagecloud.io/prometheus-rpm/release/gpgkey
       https://raw.githubusercontent.com/lest/prometheus-rpm/master/RPM-GPG-KEY-prometheus-rpm
gpgcheck=1
metadata_expire=300
EOF
dnf install -y node_exporter

# Not sure if this is needed: (adds --collector.processes to ARGS for the node exporter service)
# sed -i -E "s/^(NODE_EXPORTER_OPTS=([\"'])[^']*)\2\s*$/\1 --collector.processes\2/" /etc/default/node_exporter

systemctl enable --now node_exporter


exit 0
