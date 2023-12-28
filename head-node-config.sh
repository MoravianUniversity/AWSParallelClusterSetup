#!/bin/bash

# This script runs on the head node of the cluster after the cluster/Slurm
# setup is complete. It initializes the following:
#  - custom prolog and epilog

# Source the AWS ParallelCluster profile
. /etc/parallelcluster/cfnconfig
export AWS_DEFAULT_REGION="$cfn_region"

# Download the CSV file
function download() {
    URI="$1"
    OUTPUT="$2"
    TEMP_FILE="/tmp/$(basename "$URI")"
    if [[ "$URI" =~ ^s3 ]]; then
        aws s3 cp "$URI" "$TEMP_FILE" --no-progress || exit 1
    else
        wget -nv -O "$TEMP_FILE" "$URI" || exit 1
    fi
    if [[ "$URI" =~ \.tar\.gz$ ]]; then
        tar -xzf "$TEMP_FILE" -C "$OUTPUT"
    elif [[ "$URI" =~ \.gz$ ]]; then
        gunzip -c "$TEMP_FILE" >"$OUTPUT/$(basename "$URI" .gz)"
    else
        mv "$TEMP_FILE" "$OUTPUT/$(basename "$URI")"
    fi
}

# Add prolog from argument 1
[[ "$1" =~ ^(s3|http|https)://.* ]] && download "$1" "/opt/slurm/etc/scripts/prolog.d"

# Add epilog from argument 2
[[ "$2" =~ ^(s3|http|https)://.* ]] && download "$2" "/opt/slurm/etc/scripts/epilog.d"

exit 0
