########## Cluster Creation ##########
# Script for helping setup the AWS parallel cluster
# This is not designed to be run as a script, but rather to be run line-by-line
# in a terminal. Some parts are not re-entrant either.

##### Basic AWS Setup #####
# On AWS Console:
# - Create new EC2 key pair "hpc-pcluster" and download the .pem file
# - Create new EBS volume (~1 GB/student, can be expanded later with some work)
# - Register an elastic IP with a hpc-pcluster=true tag
# - Register domain in Route 53
# - Set that domain's DNS to point to the elastic IP
# - Create and validate a certificate for that domain in Certificate Manager
# - Add a CSV to S3 for the user keys (first colunm is username, second column is public key)
# - Run the CloudFormation stack at https://us-east-1.console.aws.amazon.com/cloudformation/home?region=us-east-1#/stacks/create/review?stackName=pcluster-slurm-db&templateURL=https://us-east-1-aws-parallelcluster.s3.amazonaws.com/templates/1-click/serverless-database.yaml with the values:
#   - Stack name: hpc-pcluster-slurm-db
#   - Database cluster name: hpc-slurm-accounting-cluster
#   - Sizing: 0.5 to 2
#   - VPC: one generated by ParallelCluster below (out of order, I know...)
#   - CIDR blocks of 10.0.200.0/24 and 10.0.201.0/24
# FUTURE TODO: don't use redundancy for the database since it is just for accounting and can be rebuilt easily (and will be half the cost)

# Update these with any changed values
VENV="$PWD/hpc-aws"
export AWS_PROFILE="bushj"
export AWS_DEFAULT_REGION="us-east-1"
AMI_IMAGE_ID="rocky-8"
DB_CF_NAME="hpc-pcluster-slurm-db"
DOMAIN_NAME="mucluster.com"
USER_KEYS_S3="s3://mu-hpc-pcluster/user-keys.csv"
EBS_VOLUME_ID="vol-02c42f64eace590fa"
GRAFANA_SG_NAME="grafana-sg"  # this just needs to be unique to this VPC


# Allow use of spot instances (only needs to be done once for an entire AWS account)
aws iam create-service-linked-role --aws-service-name spot.amazonaws.com


##### Tool Setup #####
# Install AWS ParallelCluster tools
if ! [ -d "$VENV" ]; then
  python3 -m venv "$VENV"
fi
source "$VENV/bin/activate"
python3 -m pip install --upgrade "aws-parallelcluster"

# Install NVM and NodeJS (LTS version)
if ! [ -e "$HOME/.nvm/nvm.sh" ]; then
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.38.0/install.sh | bash
  chmod ug+x "$HOME/.nvm/nvm.sh"
  source "$HOME/.nvm/nvm.sh"
  nvm install --lts
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
fi


##### Create Config #####
# Explanation of choices in the following:
#  OS: rocky8 - free version of RHEL 8 (like what centos8 should be, exactly what Expanse uses)
#    However, no pre-built images of Rocky 8 are available, so we have to build our own
#  Head Node: t3a.medium - 2 vCPU, 4 GB RAM, burtsable, 0.0376 $/hr
#    Uses AMD EPYC 7000 series processor similar to Expanse and Bridges-2
#  Compute Node: c5a.2xlarge - 8 vCPU, 16 GB RAM, 0.308 $/hr (spot price 0.1539 $/hr)
#    Uses AMD EPYC 7002 series processor exaclty like Expanse and Bridges-2
#    NOTE: This is not EFA compatible so it will be slow for MPI (but all of the EFA compatible instances are WAY more expensive: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa.html#efa-instance-types)
#    TODO: A c5ad.2xlarge node costs a bit more (~2c/hr) but has a 300 GB NVMe SSD for ephemeral storage
#  The "2" option at the end causes us to make all machines public (instead of the 1/default option which makes compute nodes private)
#    Would like the compute fleet to be in private subnet, but that would cost $150+ for the semester
if ! [ -e pcluster-config.yaml ]; then
    pcluster configure --config pcluster-config.yaml
    # Options:
    # us-east-1
    # hpc-pcluster
    # slurm
    # rocky8
    # t3a.medium
    # 1
    # compute
    # 1
    # c5a.2xlarge
    # 24
    # y
    # us-east-1a
    # 2
    #---------
    # Creates VPC but does not actually launch the cluster itself yet
fi

##### Build Rocky 8 image #####
# From https://ciq.com/blog/how-to-use-aws-parallelcluster-3-8-0-with-rocky-linux-8/
# Create rocky-8.yaml file as described there but needed to:
#  - update version to 8.9 and AMI link according to https://rockylinux.org/cloud-images/
#  - add Image.RootVolume.Size parameter since it was running out of room (set it to 48 GB, default was ~37 GB)
# TODO
pcluster build-image --image-id "$AMI_IMAGE_ID" --image-configuration rocky-8.yaml
# Takes about an hour to build... check progress with:
#pcluster describe-image --image-id "$AMI_IMAGE_ID"
#pcluster list-images --image-status PENDING
# If it fails need to do a rollback on the CloudFormation stack and delete the stack


##### Update Config #####
if ! which yq >/dev/null 2>&1; then brew install yq; fi
if ! which jq >/dev/null 2>&1; then brew install jq; fi

#AMI_ID="$(pcluster describe-image --image-id "$AMI_IMAGE_ID" --query 'ec2AmiInfo.amiId')"
#AMI_ID="$(pcluster list-images --image-status AVAILABLE --query "images[?imageId=='$AMI_IMAGE_ID'].ec2AmiInfo.amiId")"
# TODO: yq -i '.Image.CustomAmi = '"$AMI_ID" pcluster-config.yaml

# Set IP address
ELASTIC_IPS="$(aws ec2 describe-addresses --filters "Name=tag:hpc-pcluster,Values=true" "Name=domain,Values=vpc" --query "Addresses[?NetworkInterfaceId == null].PublicIp")"
if [ "$ELASTIC_IPS" = "[]" ]; then echo "!!! No elastic IPs available !!!";
elif [ "$(jq length <<<"$ELASTIC_IPS")" -gt 1 ]; then
    # FUTURE TODO
    echo "!!! Multiple elastic IPs available !!!";
    ELASTIC_IP="$(jq -r '.[0]' <<<"$ELASTIC_IPS")"
    yq -i '.HeadNode.Networking.ElasticIp = "'"$ELASTIC_IP"'"' pcluster-config.yaml
else
    ELASTIC_IP="$(jq -r '.[0]' <<<"$ELASTIC_IPS")"
    yq -i '.HeadNode.Networking.ElasticIp = "'"$ELASTIC_IP"'"' pcluster-config.yaml
fi

# Add persistent EBS volume for /home
yq -i '.SharedStorage += [{
    "MountDir": "/home",
    "Name": "home",
    "StorageType": "Ebs",
    "EbsSettings": { "VolumeId": "'"$EBS_VOLUME_ID"'" }
}]' pcluster-config.yaml

# Add initialization scripts
REPO="$(git remote get-url origin | sed -E -e 's~^(git@[^:]+:|https?://[^/]+/)([[:graph:]]*).git~\2~')"
REPO_URL="https://raw.githubusercontent.com/$REPO/main"
HN_SETUP_SCRIPT="$REPO_URL/head-node-setup.sh"
yq -i '.HeadNode.CustomActions.OnNodeStart.Sequence += [{"Script":"'"$HN_SETUP_SCRIPT"'","Args":["'"$DOMAIN_NAME"'","'"$USER_KEYS_S3"'"]}]' pcluster-config.yaml
S3_BUCKET="$(sed -E -e "s~^s3://([^/]*)/(.*)$~\1~" <<< "$USER_KEYS_S3")"
S3_KEY="$(sed -E -e "s~^s3://([^/]*)/(.*)$~\2~" <<< "$USER_KEYS_S3")"
yq -i '.HeadNode.Iam.S3Access += [{"BucketName":"'"$S3_BUCKET"'","KeyName":"'"$S3_KEY"'"}]' pcluster-config.yaml

CN_SETUP_SCRIPT="$REPO_URL/compute-node-setup.sh"
yq -i '.Scheduling.SlurmQueues[0].CustomActions.OnNodeStart.Sequence += [{"Script":"'"$CN_SETUP_SCRIPT"'"]}]' pcluster-config.yaml

# Add custom prolog/epilog scripts
HN_CONFIG_SCRIPT="$REPO_URL/head-node-config.sh"
PROLOG="$REPO_URL/50_hpc_cluster_slurm_prolog"
EPILOG="$REPO_URL/50_hpc_cluster_slurm_epilog"
yq -i '.HeadNode.CustomActions.OnNodeConfigured.Sequence += [{"Script":"'"$HN_CONFIG_SCRIPT"'","Args":["'"$PROLOG"'","'"$EPILOG"'"]}]' pcluster-config.yaml

# All other configuration changes
yq -i '. *d load("pcluster-config-extras.yaml")' pcluster-config.yaml

# Integrate Accounting
DB_URI="$(aws cloudformation describe-stacks --stack-name "$DB_CF_NAME" --query "Stacks[0].Outputs[?OutputKey=='DatabaseHost'].OutputValue" --output text)"
DB_PORT="$(aws cloudformation describe-stacks --stack-name "$DB_CF_NAME" --query "Stacks[0].Outputs[?OutputKey=='DatabasePort'].OutputValue" --output text)"
DB_USERNAME="$(aws cloudformation describe-stacks --stack-name "$DB_CF_NAME" --query "Stacks[0].Outputs[?OutputKey=='DatabaseAdminUser'].OutputValue" --output text)"
DB_SECRET_ARN="$(aws cloudformation describe-stacks --stack-name "$DB_CF_NAME" --query "Stacks[0].Outputs[?OutputKey=='DatabaseSecretArn'].OutputValue" --output text)"
DB_SEC_GROUP="$(aws cloudformation describe-stacks --stack-name "$DB_CF_NAME" --query "Stacks[0].Outputs[?OutputKey=='DatabaseClientSecurityGroup'].OutputValue" --output text)"
yq -i '.HeadNode.Networking.AdditionalSecurityGroups += ["'"$DB_SEC_GROUP"'"]' pcluster-config.yaml
yq -i '.Scheduling.SlurmSettings.Database.Uri = "'"$DB_URI:$DB_PORT"'"' pcluster-config.yaml
yq -i '.Scheduling.SlurmSettings.Database.UserName = "'"$DB_USERNAME"'"' pcluster-config.yaml
yq -i '.Scheduling.SlurmSettings.Database.PasswordSecretArn = "'"$DB_SECRET_ARN"'"' pcluster-config.yaml


##### Setup Grafana #####
SUBNET_ID="$(yq ".HeadNode.Networking.SubnetId" pcluster-config.yaml)"
VPC_ID="$(aws ec2 describe-subnets --subnet-ids "$SUBNET_ID" --query "Subnets[0].VpcId" --output text)"
GF_SEC_GROUP="$(aws ec2 create-security-group --group-name "$GRAFANA_SG_NAME" --description "Open HTTP/HTTPS ports" --vpc-id "$VPC_ID" --output text 2>/dev/null)"
if [ -n "$GF_SEC_GROUP" ]; then
    # newly created security group
    aws ec2 authorize-security-group-ingress --group-id "$GF_SEC_GROUP" --protocol tcp --port 443 --cidr 0.0.0.0/0
    aws ec2 authorize-security-group-ingress --group-id "$GF_SEC_GROUP" --protocol tcp --port 80 --cidr 0.0.0.0/0
else
    # already exists
    GF_SEC_GROUP="$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$GRAFANA_SG_NAME" "Name=vpc-id,Values=$VPC_ID" --query "SecurityGroups[0].GroupId" --output text)"
fi
yq -i '.HeadNode.Networking.AdditionalSecurityGroups += ["'"$GF_SEC_GROUP"'"]' pcluster-config.yaml
CERT="$(aws acm list-certificates --certificate-statuses ISSUED --query "CertificateSummaryList[?contains(SubjectAlternativeNameSummaries, '$DOMAIN_NAME') || DomainName == '$DOMAIN_NAME'].CertificateArn" --output text)"
# TODO: create IAM policy for grafana to access the certificate whose ARN is in CERT
# {
#     "Version": "2012-10-17",
#     "Statement": [
#         {"Sid": "GetCert", "Effect": "Allow", "Action": "acm:GetCertificate", "Resource": "$CERT"},
#         {"Sid": "ListCerts", "Effect": "Allow", "Action": "acm:ListCertificates", "Resource": "*"}
#     ]
# }
# On the server:
#     ARN="$(aws acm list-certificates --region "$cfn_region" --query "CertificateSummaryList[0].CertificateArn" --output text)"
#     aws acm get-certificate --certificate-arn arn:aws:acm:us-east-1:936771282063:certificate/d38831a7-18fc-4003-a792-3e973c21e36c --region us-east-1 --query "Certificate" --output text >> ?/certificate.crt
#     aws acm get-certificate --certificate-arn arn:aws:acm:us-east-1:936771282063:certificate/d38831a7-18fc-4003-a792-3e973c21e36c --region us-east-1 --query "CertificateChain" --output text >> ?/certificate-chain.crt
yq -i '. *d load("pcluster-grafana.yaml")' pcluster-config.yaml


##### Create the cluster #####
#pcluster create-cluster --cluster-name hpc-cluster --cluster-configuration pcluster-config.yaml
pcluster create-cluster --cluster-name hpc-cluster-test --cluster-configuration pcluster-config.yaml
# pcluster describe-cluster --cluster-name hpc-cluster-test
# pcluster ssh --region us-east-1 --cluster-name hpc-cluster-test -i hpc-pcluster.pem
# pcluster update-cluster --cluster-name hpc-cluster-test --cluster-configuration pcluster-config.yaml
# pcluster delete-cluster --cluster-name hpc-cluster-test

# Notes:
#   About 3:45 minutes to boot an instance (without grafana)

# TODO:
#   **link domain name to cluster - nearly working
#   *auto-setup users - nearly working
#       do we need to run this on the compute nodes as well?
#   **add persistent EBS volume for /home - nearly working
#   **add custom prolog/epilog scripts - nearly working
#   rocky8 image
#   Add grafana - working on
#     can install manually but has lots of problems:
#       - should auto-install on config
#       - self-signed cert and cert doesn't use domain name
#       - want a different landing page
#       - should be able to view without logging in
#       - customize the dashboards
#
# QUESTIONS/CONSIDERATIONS:
#   Get real memory amount -> 15698 for CentOS 7  (default is 15564.8) [after grafana though?]
#   Set ComputeResources.MinCount=1 to make sure there is always 1 node available?
#   Do all tools work? (MPI, etc)
