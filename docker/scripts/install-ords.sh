#!/bin/bash
# Install ORDS into the Oracle container during image build.
# This script runs as root during `docker build`.

set -euo pipefail

ORDS_VERSION="${ORDS_VERSION:-latest}"
ORDS_HOME="/opt/oracle/ords"
ORDS_CONFIG="/etc/ords/config"

echo "=== Installing ORDS ==="

# Install required packages
microdnf install -y java-17-openjdk-headless unzip curl && microdnf clean all

# Download ORDS
mkdir -p "$ORDS_HOME" "$ORDS_CONFIG"
cd /tmp
curl -fsSL -o ords.zip "https://download.oracle.com/otn_software/java/ords/ords-latest.zip"
unzip -q ords.zip -d "$ORDS_HOME"
rm ords.zip

# Make ords CLI available
ln -sf "$ORDS_HOME/bin/ords" /usr/local/bin/ords

# Set ORDS config directory
export ORDS_CONFIG
ords config set --global config.dir "$ORDS_CONFIG"

echo "=== ORDS installed to $ORDS_HOME ==="
