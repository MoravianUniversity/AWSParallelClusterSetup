#!/bin/bash

# This script runs on the head node of the cluster upon first boot before any
# other cluster/Slurm setup. It initializes the following:
#  - setting the hostname
#  - setting up additional SSH users

# Source the AWS ParallelCluster profile
. /etc/parallelcluster/cfnconfig

##### General setup #####
dnf install nano

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

##### Set up host keys if provided in argument 3 #####
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


##### Grafana Setup #####
ORG_NAME="Moravian University"
DOMAIN="mucluster.com"
REGION="us-east-1"
EMAIL="bushj@moravian.edu"

dnf install -y nginx grafana certbot python3-certbot-nginx
dnf install -y prometheus2 node_exporter

# Update Grafana Settings
# TODO: doesn't do just one replacement but many
sed -i -E "/[auth.anonymous]/,/enabled/  s/;?enabled\s*=\s*.+/enabled = true/" /etc/grafana/grafana.ini  # enable anonymous access
sed -i -E "/[auth.anonymous]/,/org_name/  s/;?org_name\s*=\s*.+/org_name = $ORG_NAME/" /etc/grafana/grafana.ini
sed -i -E "/[server]/,/domain/  s/;?domain\s*=\s*.+/domain = $DOMAIN/" /etc/grafana/grafana.ini
sed -i -E "/[security]/,/admin_password/  s/;?admin_password\s*=\s*.+/admin_password = Grafana4PC/" /etc/grafana/grafana.ini # TODO
#sed -i -E "/[alerting]/,/enabled/  s/;?enabled\s*=\s*.+/enabled = false/" /etc/grafana/grafana.ini

# Generate SSL Certificate
certbot -n --nginx --agree-tos -m "$EMAIL" -d "$DOMAIN"

# Update prometheus config to allow nginx proxy
sed -i -E "s~^(PROMETHEUS_OPTS=([\"'])[^']*)\2\s*$~\1 --web.external-url /prometheus/ --web.route-prefix /\2~" /etc/default/prometheus

# Create Grafana data source config
cat >/etc/grafana/provisioning/datasources/datasources.yml <<EOF
apiVersion: 1
datasources:
  - name: prometheus
    type: prometheus
    access: proxy
    url: http://localhost:9090
    isDefault: true
    editable: true
    jsonData:
      timeInterval: 5s
  - name: cloudwatch
    type: cloudwatch
    editable: true
    jsonData:
      authType: default
      defaultRegion: $REGION
EOF
chown root:grafana /etc/grafana/provisioning/datasources/datasources.yml
chmod 640 /etc/grafana/provisioning/datasources/datasources.yml

# Create Grafana nginx proxy config
cat >/etc/nginx/conf.d/grafana.conf <<EOF
map \$http_upgrade \$connection_upgrade {
  default upgrade;
  '' close;
}

upstream grafana {
  server localhost:3000;
}

#server {
#  listen 80 default_server;
#  listen [::]:80 default_server;
#  server_name _;
#  return 301 https://\$host\$request_uri;
#}

# TODO: how to combine with the CertBot added stuff?
server {
  listen 443 ssl;
  ssl_certificate /etc/letsencrypt/live/mucluster.com/fullchain.pem; # managed by Certbot
  ssl_certificate_key /etc/letsencrypt/live/mucluster.com/privkey.pem; # managed by Certbot
  include /etc/letsencrypt/options-ssl-nginx.conf; # managed by Certbot
  ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem; # managed by Certbot
  server_name $DOMAIN;
  server_tokens off;

  root /usr/share/nginx/html;
  index index.html index.htm;

  # Expose internal services for testing
  location ^~ /prometheus/ {
    proxy_pass http://localhost:9090/;
    proxy_set_header Host \$http_host;
  }

  # Proxy Grafana requests.
  location / {
    proxy_set_header Host \$http_host;
    proxy_pass http://grafana;
  }

  # Proxy Grafana Live WebSocket connections.
  location /api/live/ {
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$connection_upgrade;
    proxy_set_header Host \$http_host;
    proxy_pass http://grafana;
  }
}
EOF

# slurm exporter
GOBIN=/usr/local/bin go install github.com/rivosinc/prometheus-slurm-exporter@v1.0.1
chmod 755 /usr/local/bin/prometheus-slurm-exporter
cat >/etc/systemd/system/prometheus-slurm-exporter.service <<EOF
[Unit]
Description=SLURM Exporter for Prometheus
After=network.target

[Service]
EnvironmentFile=-/etc/default/slurm-exporter
User=prometheus
ExecStart=/usr/local/bin/prometheus-slurm-exporter -slurm.cli-fallback -slurm.poll-limit 5
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
cat >/etc/default/slurm-exporter <<EOF
PATH=/opt/slurm/bin:$PATH
EOF

# prometheus config
# TODO: prometheus user cannot access AWS credentials, needs to be switched to root?
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
  #- job_name: "node_exporter"
  #  scrape_interval: 5s
  #  static_configs:
  #    - targets: ['localhost:9100']
  - job_name: 'ec2_instances'
    scrape_interval: 5s
    ec2_sd_configs:
      - port: 9100
        region: us-east-1
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


systemctl enable --now prometheus node_exporter prometheus-slurm-exporter
systemctl enable --now nginx grafana-server


exit 0
