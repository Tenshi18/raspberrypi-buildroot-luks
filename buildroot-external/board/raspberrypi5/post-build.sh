#!/bin/bash
set -e

BOARD_DIR="$(dirname $0)"
TARGET_DIR="$1"

# Install busybox links
if [ -x "${TARGET_DIR}/bin/busybox" ]; then
    ${TARGET_DIR}/bin/busybox --install -s ${TARGET_DIR}/bin
fi

# Ensure init scripts are executable
find "${TARGET_DIR}/etc/init.d" -type f -exec chmod +x {} \; 2>/dev/null || true

# Create required directories
mkdir -p "${TARGET_DIR}/etc/sdm/assets/cryptroot"

# Create directories for your custom scripts and applications
# Example: mkdir -p "${TARGET_DIR}/usr/local/bin"
# Example: mkdir -p "${TARGET_DIR}/var/log/your-app"

echo "Post-build complete for Raspberry Pi 5"

