#!/bin/bash

# This script runs on the head node of the cluster and does additional
# initialization on the cluster including:
#  - setting the hostname
#  - setting up additional SSH users

#source the AWS ParallelCluster profile
. /etc/parallelcluster/cfnconfig

# Set the hostname if provided in argument 1
if [[ "$1" =~ ^[a-zA-Z0-9_-]+([.][a-zA-Z0-9_-]+)+$ ]]; then
    echo "Setting hostname to $1"
    hostnamectl hostname "$1"
fi

# Set up additional SSH users if provided in argument 2
if [[ "$2" =~ ^(s3|http|https)://.* ]]; then
    echo "Setting up additional SSH users from $2"
    CSV_FILE="/tmp/users.csv"
    if [[ "$2" =~ ^s3 ]]; then
        REGION=$(cut -d "." -f 2 <<<"$2")
        aws s3 cp "$2" "$CSV_FILE" --no-progress
    else
        wget -nv -O "$CSV_FILE" "$2"
    fi
    while IFS=, read -r NEW_USER KEY; do
        if [[ "$NEW_USER" =~ ^(root|centos|ec2-user|rocky|ubuntu)$ ]]; then echo "!!! Cannot create user $NEW_USER !!!"; continue fi
        id $NEW_USER >/dev/null 2>&1 || sudo useradd "$NEW_USER" -m
        if [[ ! -d "/home/$NEW_USER" ]]; then echo "!!! Cannot create user $NEW_USER !!!"; continue; fi
        sudo mkdir -p -m 0700 "/home/$NEW_USER/.ssh"
        if ! sudo grep -q $(cut -f2 -d " " <<<"$KEY") /home/$NEW_USER/.ssh/authorized_keys >/dev/null 2>&1; then
            sudo tee "/home/$NEW_USER/.ssh/authorized_keys" <<<"$KEY" >/dev/null
        fi
        sudo chown -R "$NEW_USER:$NEW_USER" "/home/$NEW_USER/.ssh"
        sudo chmod 0600 "/home/$NEW_USER/.ssh/authorized_keys"
    done < "$CSV_FILE"
fi
