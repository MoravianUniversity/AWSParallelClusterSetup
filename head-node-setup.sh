#!/bin/bash

# This script runs on the head node of the cluster upon first boot before any
# other cluster/Slurm setup. It initializes the following:
#  - setting the hostname
#  - setting up additional SSH users

# Source the AWS ParallelCluster profile
. /etc/parallelcluster/cfnconfig

# Set the hostname if provided in argument 1
if [[ "$1" =~ ^[a-zA-Z0-9_-]+([.][a-zA-Z0-9_-]+)+$ ]]; then
    echo "Setting hostname to '$1'"
    hostnamectl set-hostname "$1"
    echo "127.0.0.1 $1" >>/etc/hosts
fi

# Set restrictive default umask
mkdir -p -m 0755 /etc/profile.d
cat >/etc/profile.d/set-umask.sh <<EOF
# Set restrictive default umask
umask 077
EOF
cp /etc/profile.d/set-umask.sh /etc/profile.d/set-umask.csh

# Set up user.txt file
touch /opt/parallelcluster/shared/users.txt
chmod 0600 /opt/parallelcluster/shared/users.txt

# Set up additional SSH users if provided in argument 2
if [[ "$2" =~ ^(s3|http|https)://.* ]]; then
    # Create a script for this so it can be used again at a later time
    SCRIPT_FILE="/root/create-users.sh"
    cat >"$SCRIPT_FILE" <<EOF
export AWS_DEFAULT_REGION="$cfn_region"
DEFAULT_URI="$2"

EOF
    cat >>"$SCRIPT_FILE" <<'EOF'
function trim_csv() {
    X=$(sed -e "s/^[[:space:]]*//" -e "s/[[:space:]]*$//" <<< "$1")
    if [[ ${X::1} == '"' ]] && [[ ${X: -1} == '"' ]]; then
        X="$(sed -e 's/""/"/g' <<< "${X:1:-1}")"
    fi
    echo "$X"
}

USERS_GID="$(getent group users | cut -d : -f 3)"

# Download the CSV file
[ -n "$1" ] && URI="$1" || URI="$DEFAULT_URI"
echo "Setting up SSH users from $URI"
CSV_FILE="/tmp/users.csv"
if [[ "$URI" =~ ^s3 ]]; then
    aws s3 cp "$URI" "$CSV_FILE" --no-progress || exit 1
else
    wget -nv -O "$CSV_FILE" "$URI" || exit 1
fi

# Go through each line of the CSV file
while IFS=, read -r NEW_USER KEY; do
    # Remove leading and trailing whitespace and quotes
    NEW_USER="$(trim_csv "$NEW_USER")"
    KEY="$(trim_csv "$KEY")"

    # Skip empty lines and lines with missing or bad values
    if [ -z "$NEW_USER" ] || [ -z "$KEY" ]; then echo "Skipping '$NEW_USER','$KEY'"; continue; fi
    if [[ "$NEW_USER" =~ ^(root|centos|ec2-user|rocky|ubuntu)$ ]]; then echo "!!! Cannot create user $NEW_USER !!!"; continue; fi

    # Create the user
    HOME_DIR="/home/$NEW_USER"
    if ! id $NEW_USER >/dev/null 2>&1; then
        # User does not exist
        echo "Creating user '$NEW_USER'"
        if [[ -d "$HOME_DIR" ]]; then
            # Already has a home directory
            useradd -d "$HOME_DIR" -M -N -g "$USERS_GID" "$NEW_USER"
            chown -R "$NEW_USER:users" "$HOME_DIR"
        else
            # Make a new home directory
            useradd -d "$HOME_DIR" -m -N -g "$USERS_GID" "$NEW_USER"
        fi
        chmod 0700 "$HOME_DIR"

        # Save information about the user
        NEW_UID="$(id -u "$NEW_USER")"
        echo "$NEW_UID $NEW_USER" >> /opt/parallelcluster/shared/users.txt
    fi
    if [[ ! -d "$HOME_DIR" ]]; then echo "!!! Failed to create user $NEW_USER !!!"; continue; fi

    # Add the SSH key
    SSH_DIR="$HOME_DIR/.ssh"
    AUTH_KEYS="$SSH_DIR/authorized_keys"
    if ! grep -q $(cut -f2 -d " " <<<"$KEY") "$AUTH_KEYS" >/dev/null 2>&1; then
        echo "Adding SSH key for '$NEW_USER'"
        mkdir -p -m 0700 "$SSH_DIR"
        echo "$KEY" >>"$AUTH_KEYS"
    fi

    # Fix permissions
    chown -R "$NEW_USER:users" "$SSH_DIR"
    chmod 0600 "$AUTH_KEYS"
done < "$CSV_FILE"

exit 0
EOF
    chmod 0755 "$SCRIPT_FILE"

    # Run the script
    "$SCRIPT_FILE"
fi

# Set up host keys if provided in argument 3
if [[ "$3" =~ ^(s3|http|https)://.* ]]; then
    echo "Adding host keys from $3"
    TARBALL="/tmp/ssh-host-keys.tar.gz"
    if [[ "$3" =~ ^s3 ]]; then
        aws s3 cp "$3" "$TARBALL" --no-progress || exit 1
    else
        wget -nv -O "$TARBALL" "$3" || exit 1
    fi
    tar --overwrite -C /etc/ssh -xzf "$TARBALL"
    chown root:ssh_keys /etc/ssh/ssh_host_*_key
    chown root:root /etc/ssh/ssh_host_*_key.pub
    chmod 0640 /etc/ssh/ssh_host_*_key
    chmod 0644 /etc/ssh/ssh_host_*_key.pub
    systemctl restart sshd
fi

exit 0
