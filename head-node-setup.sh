#!/bin/bash

# This script runs on the head node of the cluster and does additional
# initialization on the cluster including:
#  - setting the hostname
#  - setting up additional SSH users

# Source the AWS ParallelCluster profile
. /etc/parallelcluster/cfnconfig

# Set the hostname if provided in argument 1
if [[ "$1" =~ ^[a-zA-Z0-9_-]+([.][a-zA-Z0-9_-]+)+$ ]]; then
    echo "Setting hostname to '$1'"
    hostnamectl set-hostname "$1"
fi

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

    # Skip empty lines and lines with missing values
    if [ -z "$NEW_USER" ] || [ -z "$KEY" ]; then echo "Skipping $NEW_USER,$KEY"; continue; fi
    if [[ "$NEW_USER" =~ ^(root|centos|ec2-user|rocky|ubuntu)$ ]]; then echo "!!! Cannot create user $NEW_USER !!!"; continue; fi

    # Create the user
    echo "Creating user '$NEW_USER'"
    id $NEW_USER >/dev/null 2>&1 || useradd "$NEW_USER" -m
    if [[ ! -d "/home/$NEW_USER" ]]; then echo "!!! Cannot create user $NEW_USER !!!"; continue; fi

    # Add the SSH key
    echo "Adding SSH key for '$NEW_USER'"
    mkdir -p -m 0700 "/home/$NEW_USER/.ssh"
    if ! grep -q $(cut -f2 -d " " <<<"$KEY") /home/$NEW_USER/.ssh/authorized_keys >/dev/null 2>&1; then
        tee "/home/$NEW_USER/.ssh/authorized_keys" <<<"$KEY" >/dev/null
    fi

    # Fix permissions
    chown -R "$NEW_USER:$NEW_USER" "/home/$NEW_USER/.ssh"
    chmod 0600 "/home/$NEW_USER/.ssh/authorized_keys"
done < "$CSV_FILE"
exit 0
EOF
chmod 0755 "$SCRIPT_FILE"

# Run the script
"$SCRIPT_FILE"

fi

exit 0
