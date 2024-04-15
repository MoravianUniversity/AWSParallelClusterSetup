#!/bin/bash

# This script runs on the compute node of the cluster upon first boot before
# any other cluster/Slurm setup. It initializes the following:
#  - installing necessary packages
#  - setting up default profiles
#  - setting up additional SSH users
#  - setting up node exporter
#  - setting up NVIDIA CUDA drivers

# This script must be run as root.

# This script can be run on a test machine to create the AMI for the compute nodes
# for faster booting. It will still be required to run on first boot of the compute
# nodes as well to finish setting up the users, but the rest of the setup will be
# MUCH faster (about 1.5-2 minutes faster - 30-40% of the boot time!).

# To create AMI: (using the web console, this can be done from CLI but I haven't figured out the commands yet - only need it for steps 1, 6, and 7)
#    1. Launch an appropriate instance with the base parallel-cluster modified Rocky Linux 8.8 AMI
#    2. SSH into the instance
#    3. Become root (sudo su)
#    4. Run this script
#    5. Run /usr/local/sbin/ami_cleanup.sh
#    6. In the console:
#       a. Select the instance
#       b. Instance State > Stop
#       c. Actions > Image and Templates > Create image
#    7. Once fully created (the AMI becomes "Available" - this takes up to 15 minutes), delete the instance
#    8. Update the ParallelCluster configuration to use the new AMI (Scheduling > SlurmQueues > Image > CustomAmi)



##### General setup #####
if ! which nano &>/dev/null || ! which valgrind &>/dev/null; then
    dnf install -y nano htop valgrind gcc-toolset-13 numactl
    dnf install -y hwloc gnuplot msr-tools # tools used by the textbook
fi

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
if [ -f "/opt/parallelcluster/shared/users.txt" ]; then
    echo "Creating users..."
    USERS_GID="$(getent group users | cut -d : -f 3)"
    while read -r NEW_UID NEW_USER; do
        useradd -d "/home/$NEW_USER" -M -N -g "$USERS_GID" -u "$NEW_UID" "$NEW_USER"
    done < "/opt/parallelcluster/shared/users.txt"
fi


##### Set up node exporter #####
if ! which node_exporter &>/dev/null; then
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
fi


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

##### NVIDIA CUDA Setup #####
if lspci | grep -q NVIDIA && ! lsmod | grep -q nvidia ; then
    # Install NVIDIA drivers
    dnf update -y && dnf upgrade -y
    dnf config-manager -y --add-repo https://developer.download.nvidia.com/compute/cuda/repos/rhel8/x86_64/cuda-rhel8.repo
    #dnf install kernel-devel-$(uname -r) kernel-headers-$(uname -r)
    dnf install -y nvidia-driver nvidia-settings
    dnf install -y cuda-driver cuda-12-4
    
    # Modify /usr/include/bits/floatn.h and /usr/include/bits/floatn-common.h to fix the compile-time errors with CUDA 12.4 and gcc 13.1
    sed -i 's/^\( *# *if *!__GNUC_PREREQ *(7, *0) *||\) *defined *__cplusplus *$/\1 (defined __cplusplus \&\& !__GNUC_PREREQ (13, 0))/' /usr/include/bits/floatn.h
    sed -i 's/^\( *# *if *!__GNUC_PREREQ *(7, *0) *||\) *defined *__cplusplus *$/\1 (defined __cplusplus \&\& !__GNUC_PREREQ (13, 0))/' /usr/include/bits/floatn-common.h

    # Enable profiling for all users
    cat >/etc/modprobe.d/nvidia_profile_perm.conf <<EOF
options nvidia NVreg_RestrictProfilingToAdminUsers=0
EOF

    # Reboot to load the NVIDIA driver
    reboot now
fi

if lspci | grep -q NVIDIA; then
    # Set up CUDA environment variables
    cat >/etc/profile.d/cuda.sh <<'EOF'
export PATH="/usr/local/cuda/bin:$PATH"
export LD_LIBRARY_PATH="/usr/local/cuda/lib64:$LD_LIBRARY_PATH"
EOF
    chmod 644 /etc/profile.d/cuda.sh
    cp /etc/profile.d/cuda.sh /etc/profile.d/cuda.csh

    # Enable profiling for all users (only needed if the driver was already loaded and the conf file was not set up)
    rmmod nvidia_uvm || true
    rmmod nvidia_drm || true
    rmmod nvidia_modeset || true
    killall nvidia-pe || true
    killall nvidia || true
    rmmod nvidia || true
    modprobe nvidia NVreg_RestrictProfilingToAdminUsers=0 || true
    modprobe nvidia_modeset || true
    modprobe nvidia_drm || true
    modprobe nvidia_uvm || true
fi


exit 0
