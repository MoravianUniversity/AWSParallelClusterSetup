#!/bin/bash

# This script runs on the head node of the cluster upon first boot before any
# other cluster/Slurm setup. It initializes the following:
#  - setting the hostname
#  - setting up additional SSH users
#  - setting up host keys
#  - setting up Grafana
#  - setting up Prometheus and metric exporting tools

# Source the AWS ParallelCluster profile
. /etc/parallelcluster/cfnconfig

##### General setup #####
dnf install -y nano htop valgrind gcc-toolset-13
dnf install -y hwloc qcachegrind gnuplot msr-tools # tools used by the textbook

git clone https://github.com/RRZE-HPC/likwid.git
cd likwid
#edit config.mk
make && make install
cd ..

# Prevent users from writing to each other's terminals
sudo chmod -007 /usr/bin/wall || true
sudo chmod -007 /usr/bin/write || true
cat >/etc/profile.d/protect-tty.sh <<'EOF'
test -O "$(/usr/bin/tty)" && /usr/bin/mesg n
EOF
sudo chmod 644 /etc/profile.d/protect-tty.sh

# Allow users to run chsh without a password
cat >/etc/pam.d/chsh <<EOF
auth       sufficient   pam_shells.so
EOF

# Restrict memory and CPU usage
mkdir -p /etc/systemd/system/user-.slice.d
cat > /etc/systemd/system/user-.slice.d/50-memory-and-cpu.conf << EOF
[Slice]
MemoryAccounting=true
MemoryMax=2G
CPUAccounting=true
CPUQuota=15%
EOF
systemctl daemon-reload

# A script that can download from either a URL or an S3 bucket
DOWNLOAD_SCRIPT_FILE='/root/download-file.sh'
cat >"$DOWNLOAD_SCRIPT_FILE" <<EOF
export AWS_DEFAULT_REGION="$cfn_region"
EOF
cat >>"$DOWNLOAD_SCRIPT_FILE" <<'EOF'
if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Usage: $0 <URI> <output file>"
    exit 1
fi
echo "Downloading $1 to $2..."
if [[ "$1" =~ ^s3 ]]; then
    aws s3 cp "$1" "$2" --no-progress || exit 1
else
    wget -nv -O "$2" "$1" || exit 1
fi
EOF
chmod 0755 "$DOWNLOAD_SCRIPT_FILE"


##### Set the hostname if provided in argument 1 #####
if [[ "$1" =~ ^[a-zA-Z0-9_-]+([.][a-zA-Z0-9_-]+)+$ ]]; then
    echo "Setting hostname to '$1'"
    hostnamectl set-hostname "$1"
    echo "127.0.0.1 $1" >>/etc/hosts
fi

##### Set restrictive default umask #####
mkdir -p -m 0755 /etc/profile.d
cat >/etc/profile.d/set-umask.sh <<EOF
# Set restrictive default umask
umask 077
EOF
cp /etc/profile.d/set-umask.sh /etc/profile.d/set-umask.csh

##### Set up user.txt file #####
touch /opt/parallelcluster/shared/users.txt
chmod 0600 /opt/parallelcluster/shared/users.txt

##### Set up additional SSH users if provided in argument 2 #####
if [[ "$2" =~ ^(s3|http|https)://.* ]]; then
    # Create a script for this so it can be used again at a later time
    SCRIPT_FILE="/root/create-users.sh"
    cat >"$SCRIPT_FILE" <<EOF
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
/root/download-file.sh "$URI" "$CSV_FILE"

# Ensure file ends in a newline (otherwise the last line is skipped)
[[ $(tail -c1 "$CSV_FILE" | wc -l) -gt 0 ]] || echo >> "$CSV_FILE"

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

##### Set up host keys if provided in argument 3 #####
if [[ "$3" =~ ^(s3|http|https)://.* ]]; then
    echo "Adding host keys from $3"
    /root/download-file.sh "$3" "/tmp/ssh-host-keys.tar.gz"
    tar --overwrite -C /etc/ssh -xzf "/tmp/ssh-host-keys.tar.gz"
    chown root:ssh_keys /etc/ssh/ssh_host_*_key
    chown root:root /etc/ssh/ssh_host_*_key.pub
    chmod 0640 /etc/ssh/ssh_host_*_key
    chmod 0644 /etc/ssh/ssh_host_*_key.pub
    systemctl restart sshd
fi


##### Grafana/Prometheus Setup #####
DOMAIN="mucluster.com"
EMAIL="bushj@moravian.edu"

# Install packages
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
dnf install -y golang-bin \
    nginx grafana certbot python3-certbot-nginx \
    prometheus2 node_exporter

# Load Grafana settings from 4th argument if provided
# Created from tar -czf ../grafana.tar.gz * from inside the grafana directory
if [[ "$4" =~ ^(s3|http|https)://.* ]]; then
  /root/download-file.sh "$4" /tmp/grafana.tar.gz
  tar -C /etc/grafana -xzf /tmp/grafana.tar.gz
  chown -R root:grafana /etc/grafana
  find /etc/grafana -type d -exec chmod 755 {} \;
  find /etc/grafana -type f -exec chmod 644 {} \;
fi

# TODO: update organization name? or don't change anon org name?
# TODO: set default dashboard? - both of these can be set in settings for admin user later, but would be nice to have it set up already
# TODO: default_home_dashboard_path, home_page?


# Generate SSL Certificate
certbot -n --nginx --agree-tos -m "$EMAIL" -d "$DOMAIN"

# Create Grafana nginx proxy config
cat >/etc/nginx/conf.d/grafana.conf <<'EOF'
map $http_upgrade $connection_upgrade {
  default upgrade;
  '' close;
}
upstream grafana {
  server localhost:3000;
}
EOF
cat >/etc/nginx/default.d/grafana.conf <<'EOF'
server_tokens off;
index index.html index.htm;

# Expose internal services for testing
location ^~ /prometheus/ {
  proxy_pass http://localhost:9090/;
  proxy_set_header Host $http_host;
}

# Proxy Grafana requests.
location / {
  proxy_set_header Host $http_host;
  proxy_pass http://grafana;
}

# Proxy Grafana Live WebSocket connections.
location /api/live/ {
  proxy_http_version 1.1;
  proxy_set_header Upgrade $http_upgrade;
  proxy_set_header Connection $connection_upgrade;
  proxy_set_header Host $http_host;
  proxy_pass http://grafana;
}
EOF
sed -i -E 's~^\s+location\s*/\s*\{~#\0~' /etc/nginx/nginx.conf  # -> comment out default nginx location /
sed -i -E '/location\s*\/\s*\{/{n;s~.*~#\0~}' /etc/nginx/nginx.conf

# SLURM Exporter
# TODO: this isn't installing automatically?
GOBIN=/usr/local/bin go install github.com/rivosinc/prometheus-slurm-exporter@v1.1.1
chmod 755 /usr/local/bin/prometheus-slurm-exporter

cat >/etc/systemd/system/prometheus-slurm-exporter.service <<EOF
[Unit]
Description=SLURM Exporter for Prometheus
After=network.target

[Service]
EnvironmentFile=-/etc/default/slurm-exporter
User=prometheus
ExecStart=/usr/local/bin/prometheus-slurm-exporter -slurm.cli-fallback -slurm.poll-limit 5
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
cat >/etc/default/slurm-exporter <<EOF
PATH=/opt/slurm/bin:$PATH
EOF

# Update prometheus config to allow nginx proxy
sed -i -E "s~^(PROMETHEUS_OPTS=([\"'])[^']*)\2\s*$~\1 --web.external-url /prometheus/ --web.route-prefix /\2~" /etc/default/prometheus

# Prometheus user cannot access AWS credentials, needs to be switched to root (default)
# TODO: any way to avoid this? https://serverfault.com/questions/1152450/aws-automatic-iam-roles-for-service-users
sed -i -E "s/^User=/#\0/" /usr/lib/systemd/system/prometheus.service

# Prometheus Config
mkdir -p /etc/prometheus
cat >/etc/prometheus/prometheus.yml <<EOF
global:
  scrape_interval: 15s # Set the scrape interval to every 15 seconds. Default is every 1 minute.
  evaluation_interval: 15s # Evaluate rules every 15 seconds. The default is every 1 minute.
  scrape_timeout: 15s # The default is 10s.

scrape_configs:
  - job_name: "prometheus"
    scrape_interval: 5s
    static_configs:
      - targets: ["localhost:9090"]
  - job_name: "slurm"
    scrape_interval: 10s
    scrape_timeout: 10s
    static_configs:
      - targets: ["localhost:9092"]
  - job_name: 'ec2_instances'
    scrape_interval: 5s
    ec2_sd_configs:
      - port: 9100
        region: $cfn_region
        refresh_interval: 10s

    relabel_configs:
      - source_labels: [__meta_ec2_tag_Name]
        target_label: instance_name
      - source_labels: [__meta_ec2_tag_Application]
        target_label: instance_grafana
      - source_labels: [__meta_ec2_instance_id]
        target_label: instance_id
      - source_labels: [__meta_ec2_availability_zone]
        target_label: instance_az
      - source_labels: [__meta_ec2_instance_state]
        target_label: instance_state
      - source_labels: [__meta_ec2_instance_type]
        target_label: instance_type
      - source_labels: [__meta_ec2_vpc_id]
        target_label: instance_vpc
EOF

# Start Services
systemctl enable --now prometheus node_exporter prometheus-slurm-exporter
systemctl enable --now nginx grafana-server
# nginx fails to start on first boot, this fixes it
killall nginx; systemctl start nginx

exit 0
