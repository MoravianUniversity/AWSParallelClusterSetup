#!/bin/bash

# This script runs on the compute node of the cluster upon first boot before
# any other cluster/Slurm setup. It initializes the following:
#  - setting up additional SSH users

echo "Creating users..."
USERS_GID="$(getent group users | cut -d : -f 3)"
while read -r NEW_UID NEW_USER; do
    useradd -d "/home/$NEW_USER" -M -N -g "$USERS_GID" -u "$NEW_UID" "$NEW_USER"
done < "/opt/parallelcluster/shared/users.txt"

exit 0
