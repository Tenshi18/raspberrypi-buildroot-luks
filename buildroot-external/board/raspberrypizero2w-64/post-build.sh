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

# Enable OpenRC services in default runlevel
# Ensure default runlevel directory exists
mkdir -p "${TARGET_DIR}/etc/runlevels/default"

# Create service name symlinks for OpenRC (OpenRC typically uses names without S* prefix)
# Enable dbus if it exists (required for NetworkManager)
if [ -f "${TARGET_DIR}/etc/init.d/S30dbus" ]; then
    # Create symlink without S* prefix for OpenRC compatibility
    if [ ! -e "${TARGET_DIR}/etc/init.d/dbus" ]; then
        ln -sf S30dbus "${TARGET_DIR}/etc/init.d/dbus" 2>/dev/null || true
    fi
    # Add to default runlevel
    ln -sf /etc/init.d/dbus "${TARGET_DIR}/etc/runlevels/default/dbus" 2>/dev/null || true
fi

# Enable NetworkManager if it exists
if [ -f "${TARGET_DIR}/etc/init.d/S45NetworkManager" ]; then
    # Create symlink without S* prefix for OpenRC compatibility
    if [ ! -e "${TARGET_DIR}/etc/init.d/NetworkManager" ]; then
        ln -sf S45NetworkManager "${TARGET_DIR}/etc/init.d/NetworkManager" 2>/dev/null || true
    fi
    # Add to default runlevel
    ln -sf /etc/init.d/NetworkManager "${TARGET_DIR}/etc/runlevels/default/NetworkManager" 2>/dev/null || true
fi

echo "Post-build complete for Raspberry Pi Zero 2W"
