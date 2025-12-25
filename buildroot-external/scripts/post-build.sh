#!/bin/bash
#
# post-build.sh - Buildroot post-build script for LUKS support
#
# This script runs after packages are built but before the filesystem image
# is created. It configures the rootfs for encrypted boot.
#

set -e

TARGET_DIR="$1"

echo "[post-build] Configuring rootfs for LUKS encryption..."

# Ensure init scripts are executable
if [ -d "$TARGET_DIR/etc/init.d" ]; then
    find "$TARGET_DIR/etc/init.d" -type f -exec chmod +x {} \;
fi

# Ensure unlock scripts are executable
if [ -f "$TARGET_DIR/usr/bin/sdmluksunlock" ]; then
    chmod +x "$TARGET_DIR/usr/bin/sdmluksunlock"
fi

# Create required directories
mkdir -p "$TARGET_DIR/etc/sdm/assets/cryptroot"

echo "[post-build] LUKS configuration complete"
exit 0

