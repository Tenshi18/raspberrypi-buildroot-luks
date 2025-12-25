#!/bin/bash
#
# post-image-encrypt.sh - Buildroot post-image script for LUKS encryption
#
# This script is called by Buildroot after creating the SD card image.
# It automatically encrypts the rootfs partition with a unique keyfile.
#
# Configuration via environment variables (set in Config.in or command line):
#   BR2_LUKS_ENCRYPT=y          Enable encryption
#   BR2_LUKS_KEYDIR=<path>      Directory to store keyfiles (default: $BINARIES_DIR/keys)
#   BR2_LUKS_CRYPTO=<type>      Crypto algorithm: aes or xchacha (default: aes)
#   BR2_LUKS_KEEP_UNENCRYPTED=y Keep original unencrypted image
#   BR2_LUKS_KEYFILE=<path>     Use existing keyfile instead of generating new one
#
# Usage (called by Buildroot):
#   BR2_ROOTFS_POST_IMAGE_SCRIPT="path/to/post-image-encrypt.sh"
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[post-image]${NC} $1"; }
warn() { echo -e "${YELLOW}[post-image]${NC} $1"; }
error() { echo -e "${RED}[post-image]${NC} $1" >&2; }

# Buildroot passes these variables
BINARIES_DIR="${BINARIES_DIR:-$1}"
BR2_CONFIG="${BR2_CONFIG:-$(dirname "$0")/../../.config}"

# Get config value from .config file
get_config() {
    local key="$1"
    local default="$2"
    
    if [ -f "$BR2_CONFIG" ]; then
        local value
        value=$(grep "^${key}=" "$BR2_CONFIG" 2>/dev/null | cut -d= -f2- | tr -d '"')
        [ -n "$value" ] && echo "$value" || echo "$default"
    else
        echo "$default"
    fi
}

# Check if encryption is enabled
check_encryption_enabled() {
    # Check environment variable first
    [ "$BR2_LUKS_ENCRYPT" = "y" ] && return 0
    
    # Check .config file
    local enabled
    enabled=$(get_config "BR2_LUKS_ENCRYPT" "n")
    [ "$enabled" = "y" ] && return 0
    
    return 1
}

# Find the pre-burn-encrypt.sh script
find_encrypt_script() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    # Try relative paths to find the main pre-burn-encrypt.sh in repository root
    # Note: buildroot-external/pre-burn-encrypt.sh was removed to avoid duplication
    local possible_paths=(
        "${BR2_EXTERNAL_LUKS_PI_PATH}/../pre-burn-encrypt.sh"
        "${BR2_EXTERNAL}/../pre-burn-encrypt.sh"
        "$script_dir/../../../pre-burn-encrypt.sh"
        "${BR2_EXTERNAL}/../../pre-burn-encrypt.sh"
    )
    
    for path in "${possible_paths[@]}"; do
        if [ -f "$path" ] && [ -x "$path" ]; then
            realpath "$path"
            return 0
        fi
    done
    
    error "Cannot find pre-burn-encrypt.sh script"
    error "Expected location: repository_root/pre-burn-encrypt.sh"
    return 1
}

# Generate unique keyfile
generate_keyfile() {
    local keydir="$1"
    local keyuuid
    
    keyuuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen || date +%s%N)
    local keypath="${keydir}/${keyuuid}.lek"
    
    mkdir -p "$keydir"
    dd if=/dev/urandom bs=1 count=256 of="$keypath" 2>/dev/null
    chmod 600 "$keypath"
    
    echo "$keypath"
}

# Main encryption function
do_encrypt() {
    local input_img="$1"
    local output_img="$2"
    local keyfile="$3"
    local crypto="$4"
    local encrypt_script="$5"
    
    info "Starting LUKS encryption..."
    info "  Input:  $input_img"
    info "  Output: $output_img"
    info "  Keyfile: $keyfile"
    info "  Crypto: $crypto"
    
    # Run encryption script (requires root for loop devices and cryptsetup)
    sudo "$encrypt_script" \
        --keyfile "$keyfile" \
        --crypto "$crypto" \
        "$input_img" "$output_img"
    
    return $?
}

# === Main ===

info "Buildroot post-image script for LUKS encryption"

# Check if images directory exists
if [ ! -d "$BINARIES_DIR" ]; then
    error "Images directory not found: $BINARIES_DIR"
    exit 1
fi

# Check if encryption is enabled
if ! check_encryption_enabled; then
    info "LUKS encryption not enabled (set BR2_LUKS_ENCRYPT=y to enable)"
    exit 0
fi

# Find input image
INPUT_IMG=""
for img in "sdcard.img" "disk.img" "rpi-sdcard.img"; do
    if [ -f "$BINARIES_DIR/$img" ]; then
        INPUT_IMG="$BINARIES_DIR/$img"
        break
    fi
done

if [ -z "$INPUT_IMG" ]; then
    error "No SD card image found in $BINARIES_DIR"
    error "Expected: sdcard.img, disk.img, or rpi-sdcard.img"
    exit 1
fi

info "Found image: $INPUT_IMG"

# Get configuration
KEYDIR="${BR2_LUKS_KEYDIR:-$(get_config "BR2_LUKS_KEYDIR" "$BINARIES_DIR/keys")}"
CRYPTO="${BR2_LUKS_CRYPTO:-$(get_config "BR2_LUKS_CRYPTO" "aes")}"
KEEP_ORIG="${BR2_LUKS_KEEP_UNENCRYPTED:-$(get_config "BR2_LUKS_KEEP_UNENCRYPTED" "n")}"
KEYFILE="${BR2_LUKS_KEYFILE:-$(get_config "BR2_LUKS_KEYFILE" "")}"

# Find encryption script
ENCRYPT_SCRIPT=$(find_encrypt_script) || exit 1
info "Using encryption script: $ENCRYPT_SCRIPT"

# Generate or use existing keyfile
if [ -z "$KEYFILE" ] || [ ! -f "$KEYFILE" ]; then
    info "Generating unique keyfile..."
    KEYFILE=$(generate_keyfile "$KEYDIR")
else
    info "Using existing keyfile: $KEYFILE"
    # Copy to keydir for consistency
    mkdir -p "$KEYDIR"
    cp "$KEYFILE" "$KEYDIR/"
    KEYFILE="$KEYDIR/$(basename "$KEYFILE")"
fi

# Determine output image name
INPUT_BASENAME=$(basename "$INPUT_IMG" .img)
OUTPUT_IMG="$BINARIES_DIR/${INPUT_BASENAME}-encrypted.img"

# Backup original if requested
if [ "$KEEP_ORIG" = "y" ]; then
    info "Keeping original unencrypted image"
    cp "$INPUT_IMG" "$BINARIES_DIR/${INPUT_BASENAME}-unencrypted.img"
fi

# Perform encryption
if do_encrypt "$INPUT_IMG" "$OUTPUT_IMG" "$KEYFILE" "$CRYPTO" "$ENCRYPT_SCRIPT"; then
    info "Encryption successful!"
    
    # Create symlink to encrypted image as default
    ln -sf "$(basename "$OUTPUT_IMG")" "$BINARIES_DIR/sdcard-encrypted.img"
    
    # Create info file with keyfile details
    cat > "$BINARIES_DIR/encryption-info.txt" << EOF
LUKS Encrypted Image Information
=================================
Image:      $(basename "$OUTPUT_IMG")
Keyfile:    $(basename "$KEYFILE")
Crypto:     $CRYPTO
Created:    $(date -Iseconds)

USB Key Preparation:
  1. Format USB drive with FAT32:
     sudo mkfs.vfat -F 32 /dev/sdX1
  
  2. Copy keyfile to USB drive:
     sudo mount /dev/sdX1 /mnt
     sudo cp $KEYFILE /mnt/
     sudo umount /mnt

Burn to SD Card:
  sudo dd if=$OUTPUT_IMG of=/dev/sdX bs=4M status=progress

EOF
    
    info "Created: $OUTPUT_IMG"
    info "Keyfile: $KEYFILE"
    info "Info:    $BINARIES_DIR/encryption-info.txt"
    
    # If not keeping original, replace it
    if [ "$KEEP_ORIG" != "y" ]; then
        info "Replacing original image with encrypted version"
        mv "$OUTPUT_IMG" "$INPUT_IMG"
        ln -sf "$(basename "$INPUT_IMG")" "$BINARIES_DIR/sdcard-encrypted.img"
    fi
else
    error "Encryption failed!"
    exit 1
fi

info "Post-image encryption complete!"
exit 0

