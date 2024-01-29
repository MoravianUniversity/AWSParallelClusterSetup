#!/bin/bash

# This script runs on the compute node of the cluster upon first boot before
# any other cluster/Slurm setup. It initializes the following:
#  - setting up additional SSH users


##### General setup #####
dnf install nano


##### Create users #####
echo "Creating users..."
USERS_GID="$(getent group users | cut -d : -f 3)"
while read -r NEW_UID NEW_USER; do
    useradd -d "/home/$NEW_USER" -M -N -g "$USERS_GID" -u "$NEW_UID" "$NEW_USER"
done < "/opt/parallelcluster/shared/users.txt"


##### Set up node exporter #####
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


##### Termination Detection #####
(
cd /
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
if [ "$?" -ne 0 ]; then
    echo "Error running 'curl' command" >&2
    exit 1
fi

# Periodically check for termination
while sleep 10; do
    HTTP_CODE=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s -w %{http_code} -o /dev/null http://169.254.169.254/latest/meta-data/spot/instance-action)

    if [[ "$HTTP_CODE" -eq 401 ]] ; then
        # Refreshing Authentication Token
        TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 120")
        continue
    elif [[ "$HTTP_CODE" -ne 200 ]] ; then
        # If the return code is not 200, the instance is not going to be interrupted
        continue
    fi

    # Start a graceful shutdown of the host
    sleep 120
    shutdown now
done
) &

exit 0
