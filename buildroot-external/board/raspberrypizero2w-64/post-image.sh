#!/bin/bash
set -e

BOARD_DIR="$(dirname $0)"
GENIMAGE_CFG="${BOARD_DIR}/genimage.cfg"
GENIMAGE_TMP="${BUILD_DIR}/genimage.tmp"

# Create boot config
cat > "${BINARIES_DIR}/config.txt" << EOF
# Raspberry Pi Zero 2W configuration
start_file=start.elf
fixup_file=fixup.dat

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
EOF

# Copy cmdline.txt if exists (may be from secret overlay)
if [ -f "${BOARD_DIR}/cmdline.txt" ]; then
    cp "${BOARD_DIR}/cmdline.txt" "${BINARIES_DIR}/cmdline.txt"
else
    # Default cmdline
    echo "root=/dev/mmcblk0p2 rootwait console=serial0,115200" > "${BINARIES_DIR}/cmdline.txt"
fi

# Copy firmware files from rpi-firmware/ to root (required for boot)
if [ -d "${BINARIES_DIR}/rpi-firmware" ]; then
    echo "Copying firmware files from rpi-firmware/..."
    cp -f "${BINARIES_DIR}"/rpi-firmware/*.bin "${BINARIES_DIR}"/ 2>/dev/null || true
    cp -f "${BINARIES_DIR}"/rpi-firmware/*.elf "${BINARIES_DIR}"/ 2>/dev/null || true
    cp -f "${BINARIES_DIR}"/rpi-firmware/*.dat "${BINARIES_DIR}"/ 2>/dev/null || true
    # Copy DTB overlays if they exist
    if [ -d "${BINARIES_DIR}/rpi-firmware/overlays" ]; then
        mkdir -p "${BINARIES_DIR}/overlays"
        cp -f "${BINARIES_DIR}"/rpi-firmware/overlays/* "${BINARIES_DIR}/overlays/" 2>/dev/null || true
    fi
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
