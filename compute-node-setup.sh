#!/bin/bash

# This script runs on the compute node of the cluster upon first boot before
# any other cluster/Slurm setup. It initializes the following:
#  - setting up additional SSH users
#  - setting up node exporter


##### General setup #####
dnf install -y nano htop valgrind gcc-toolset-13
dnf install -y hwloc gnuplot msr-tools # tools used by the textbook

mkdir -p -m 0755 /etc/profile.d

# Prevent users from writing to each other's terminals
chmod -007 /usr/bin/wall || true
chmod -007 /usr/bin/write || true
cat >/etc/profile.d/protect-tty.sh <<'EOF'
test -O "$(/usr/bin/tty)" && /usr/bin/mesg n
EOF
chmod 644 /etc/profile.d/protect-tty.sh
cp /etc/profile.d/protect-tty.sh /etc/profile.d/protect-tty.sh

# Allow users to run chsh without a password
cat >/etc/pam.d/chsh <<EOF
auth       sufficient   pam_shells.so
EOF

# Set restrictive default umask
cat >/etc/profile.d/set-umask.sh <<EOF
# Set restrictive default umask
umask 077
EOF
chmod 644 /etc/profile.d/set-umask.sh
cp /etc/profile.d/set-umask.sh /etc/profile.d/set-umask.csh

# Set gcc-13 as the default compiler
cat >/etc/profile.d/gcc-version.sh <<EOF
# Set gcc-13 as the default compiler
source /opt/rh/gcc-toolset-13/enable
EOF
chmod 644 /etc/profile.d/gcc-version.sh
cp /etc/profile.d/gcc-version.sh /etc/profile.d/gcc-version.csh


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
systemctl enable --now node_exporter


##### Termination Detection #####
# This hangs... but elsewhere they say to do this on config (this script is run on setup though)
# (
# cd /
# TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
# if [ "$?" -ne 0 ]; then
#     echo "Error running 'curl' command" >&2
#     exit 1
# fi
# # Periodically check for termination
# while sleep 10; do
#     HTTP_CODE=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s -w %{http_code} -o /dev/null http://169.254.169.254/latest/meta-data/spot/instance-action)
#     if [[ "$HTTP_CODE" -eq 401 ]] ; then
#         # Refreshing Authentication Token
#         TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 120")
#         continue
#     elif [[ "$HTTP_CODE" -ne 200 ]] ; then
#         # If the return code is not 200, the instance is not going to be interrupted
#         continue
#     fi
#     # Start a graceful shutdown of the host
#     sleep 120
#     shutdown now
# done
# ) &

exit 0
