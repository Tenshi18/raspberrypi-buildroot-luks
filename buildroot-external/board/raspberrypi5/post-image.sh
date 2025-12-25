#!/bin/bash
set -e

BOARD_DIR="$(dirname $0)"
GENIMAGE_CFG="${BOARD_DIR}/genimage.cfg"
GENIMAGE_TMP="${BUILD_DIR}/genimage.tmp"

# Create boot config
cat > "${BINARIES_DIR}/config.txt" << EOF
# Raspberry Pi 5 configuration
arm_64bit=1
kernel=Image
disable_overscan=1

# Initramfs for LUKS unlock (REQUIRED)
initramfs rootfs.cpio.gz followkernel

# GPU memory (minimal for headless)
gpu_mem=16

# Enable UART for debugging
enable_uart=1

# Disable Bluetooth to free UART
dtoverlay=disable-bt

# Audio off for headless
dtparam=audio=off

# Required for Pi 5
dtoverlay=vc4-kms-v3d-pi5
EOF

# Copy cmdline.txt if exists (may be from secret overlay)
if [ -f "${BOARD_DIR}/cmdline.txt" ]; then
    cp "${BOARD_DIR}/cmdline.txt" "${BINARIES_DIR}/cmdline.txt"
else
    # Default cmdline
    echo "root=/dev/mmcblk0p2 rootwait console=tty1 console=ttyAMA0,115200" > "${BINARIES_DIR}/cmdline.txt"
fi

# Generate SD card image
rm -rf "${GENIMAGE_TMP}"

genimage \
    --rootpath "${TARGET_DIR}" \
    --tmppath "${GENIMAGE_TMP}" \
    --inputpath "${BINARIES_DIR}" \
    --outputpath "${BINARIES_DIR}" \
    --config "${GENIMAGE_CFG}"

echo "Post-image complete: ${BINARIES_DIR}/sdcard.img"

