#!/bin/bash
#
# pre-burn-encrypt.sh - Encrypt Buildroot image BEFORE burning to SD card
#
# This script takes a Buildroot .img file and creates an encrypted version
# with a unique LUKS keyfile for USB key-based unlock.
#
# Usage: ./pre-burn-encrypt.sh input.img [output.img] [--keyfile /path/to/key]
#
# Requirements:
#   - cryptsetup
#   - parted
#   - kpartx (or losetup with partition support)
#   - e2fsprogs (resize2fs, mkfs.ext4)
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

function errexit() {
    echo -e "${RED}Error: $1${NC}" >&2
    # Don't call cleanup here - let trap EXIT handle it
    exit 1
}

function info() {
    echo -e "${GREEN}> $1${NC}"
}

function warn() {
    echo -e "${YELLOW}Warning: $1${NC}"
}

function cleanup() {
    # Prevent multiple cleanup calls
    [ "${CLEANUP_DONE:-0}" -eq 1 ] && return 0
    CLEANUP_DONE=1
    
    # Temporarily disable exit on error for cleanup
    set +e
    
    # Safe info output (in case variables aren't initialized)
    echo "> Cleaning up..." >&2
    
    # Unmount if mounted
    [ -n "$MOUNT_ENCRYPTED" ] && [ -d "$MOUNT_ENCRYPTED" ] && mountpoint -q "$MOUNT_ENCRYPTED" && umount "$MOUNT_ENCRYPTED" 2>/dev/null || true
    [ -n "$MOUNT_BOOT" ] && [ -d "$MOUNT_BOOT" ] && mountpoint -q "$MOUNT_BOOT" && umount "$MOUNT_BOOT" 2>/dev/null || true
    [ -n "$MOUNT_ORIG" ] && [ -d "$MOUNT_ORIG" ] && mountpoint -q "$MOUNT_ORIG" && umount "$MOUNT_ORIG" 2>/dev/null || true
    
    # Close LUKS
    if [ -n "$CRYPT_NAME" ]; then
        cryptsetup status "$CRYPT_NAME" &>/dev/null && cryptsetup luksClose "$CRYPT_NAME" 2>/dev/null || true
    fi
    
    # Detach loop devices
    [ -n "$LOOP_DEV" ] && losetup -d "$LOOP_DEV" 2>/dev/null || true
    
    # Remove temp directories
    [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ] && rm -rf "$WORK_DIR" 2>/dev/null || true
    
    # Re-enable exit on error
    set -e
}

function printhelp() {
    cat << 'EOF'
pre-burn-encrypt.sh - Encrypt Buildroot/RasPiOS image before burning

USAGE:
    sudo ./pre-burn-encrypt.sh [OPTIONS] input.img [output.img]

OPTIONS:
    --keyfile PATH      Use existing keyfile (default: generate new UUID-based key)
    --keydir PATH       Directory to store generated keyfiles (default: ./keys)
    --mapper NAME       Mapper name for encrypted rootfs (default: cryptroot)
    --crypto TYPE       Encryption type: aes or xchacha (default: aes for Pi5)
    --no-backup         Don't create backup of rootfs (faster but less safe)
    --keep-passphrase   Also enable passphrase unlock (default: keyfile only)
    --help              Show this help

EXAMPLES:
    # Basic usage - generates unique keyfile
    sudo ./pre-burn-encrypt.sh buildroot.img encrypted.img

    # Use existing keyfile
    sudo ./pre-burn-encrypt.sh --keyfile /path/to/mykey.lek buildroot.img

    # Batch create multiple unique images
    for i in {1..10}; do
        sudo ./pre-burn-encrypt.sh buildroot.img "device_${i}.img"
    done

NOTES:
    - Requires root privileges
    - Output image will be same size as input
    - Keyfile is saved to --keydir with UUID name
    - For USB key unlock, copy the .lek file to FAT32 USB drive
    
EOF
    exit 0
}

function generate_uuid() {
    # Try different UUID generation methods for different distros
    local uuid=""
    
    # Try uuidgen (Linux, util-linux)
    if command -v uuidgen &>/dev/null; then
        uuid=$(uuidgen 2>/dev/null)
        [ -n "$uuid" ] && echo "$uuid" && return 0
    fi
    
    # Try uuid -v4 (BSD, some Linux distros)
    if command -v uuid &>/dev/null; then
        uuid=$(uuid -v4 2>/dev/null)
        [ -n "$uuid" ] && echo "$uuid" && return 0
    fi
    
    # Try uuid without version (some systems)
    if command -v uuid &>/dev/null; then
        uuid=$(uuid 2>/dev/null)
        [ -n "$uuid" ] && echo "$uuid" && return 0
    fi
    
    # Try reading from /proc/sys/kernel/random/uuid (Linux)
    if [ -r /proc/sys/kernel/random/uuid ]; then
        uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null)
        [ -n "$uuid" ] && echo "$uuid" && return 0
    fi
    
    # Fallback: use openssl or /dev/urandom to generate UUID-like string
    if command -v openssl &>/dev/null; then
        uuid=$(openssl rand -hex 16 | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/' 2>/dev/null)
        [ -n "$uuid" ] && echo "$uuid" && return 0
    fi
    
    # Last resort: use /dev/urandom directly
    uuid=$(dd if=/dev/urandom bs=1 count=16 2>/dev/null | od -An -tx1 | tr -d ' \n' | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/')
    [ -n "$uuid" ] && echo "$uuid" && return 0
    
    return 1
}

function check_requirements() {
    local missing=()
    
    # Core required commands
    for cmd in cryptsetup parted losetup mkfs.ext4 resize2fs dd; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        errexit "Missing required commands: ${missing[*]}\nInstall with: apt install cryptsetup parted e2fsprogs"
    fi
    
    # Check for UUID generation capability (not required, but warn if none available)
    if ! generate_uuid &>/dev/null; then
        warn "No UUID generation method found. Keyfile names may be less unique."
    fi
    
    if [ "$EUID" -ne 0 ]; then
        errexit "This script must be run as root"
    fi
}

function generate_keyfile() {
    local keydir="$1"
    local keyuuid
    
    # Try to generate UUID using available method
    keyuuid=$(generate_uuid)
    
    # Fallback to timestamp-based name if UUID generation fails
    if [ -z "$keyuuid" ]; then
        keyuuid="key-$(date +%s)-$$-$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
        warn "UUID generation failed, using timestamp-based keyfile name"
    fi
    
    local keypath="${keydir}/${keyuuid}.lek"
    
    mkdir -p "$keydir"
    dd if=/dev/urandom bs=1 count=256 of="$keypath" 2>/dev/null
    chmod 600 "$keypath"
    
    echo "$keypath"
}

function get_partition_info() {
    local img="$1"
    local partnum="$2"
    
    # Get partition info using parted
    parted -ms "$img" unit B print | grep "^${partnum}:" | cut -d: -f2,4 | tr ':' ' '
}

function setup_loop_device() {
    local img="$1"
    
    # Setup loop device with partition scanning
    losetup --find --show --partscan "$img"
}

function get_loop_partition() {
    local loop="$1"
    local partnum="$2"
    
    # Handle both /dev/loop0p2 and /dev/loop0 styles
    if [ -b "${loop}p${partnum}" ]; then
        echo "${loop}p${partnum}"
    elif [ -b "${loop}${partnum}" ]; then
        echo "${loop}${partnum}"
    else
        # Wait a bit for partition devices to appear
        sleep 1
        partprobe "$loop" 2>/dev/null || true
        sleep 1
        
        if [ -b "${loop}p${partnum}" ]; then
            echo "${loop}p${partnum}"
        else
            errexit "Cannot find partition ${partnum} on ${loop}"
        fi
    fi
}

function encrypt_image() {
    local input_img="$1"
    local output_img="$2"
    local keyfile="$3"
    local mapper_name="$4"
    local crypto="$5"
    local keep_passphrase="$6"
    
    local cipher
    case "$crypto" in
        xchacha)
            cipher="xchacha20,aes-adiantum-plain64"
            ;;
        aes|aes-*)
            cipher="aes-xts-plain64"
            ;;
        *)
            cipher="aes-xts-plain64"
            ;;
    esac
    
    info "Creating encrypted copy of image..."
    
    # Copy input to output if different
    if [ "$input_img" != "$output_img" ]; then
        cp "$input_img" "$output_img"
    fi
    
    info "Setting up loop device for image..."
    LOOP_DEV=$(setup_loop_device "$output_img")
    info "Loop device: $LOOP_DEV"
    
    # Get partition devices
    local boot_part root_part
    boot_part=$(get_loop_partition "$LOOP_DEV" 1)
    root_part=$(get_loop_partition "$LOOP_DEV" 2)
    
    info "Boot partition: $boot_part"
    info "Root partition: $root_part"
    
    # Create temporary mount points
    WORK_DIR=$(mktemp -d)
    MOUNT_ORIG="${WORK_DIR}/orig_root"
    MOUNT_BOOT="${WORK_DIR}/boot"
    MOUNT_ENCRYPTED="${WORK_DIR}/encrypted_root"
    local rootfs_backup="${WORK_DIR}/rootfs_backup"
    
    mkdir -p "$MOUNT_ORIG" "$MOUNT_BOOT" "$MOUNT_ENCRYPTED" "$rootfs_backup"
    
    info "Mounting original rootfs..."
    mount "$root_part" "$MOUNT_ORIG"
    
    info "Backing up rootfs content..."
    # Use rsync for reliable copy
    rsync -aHAXx --info=progress2 "$MOUNT_ORIG/" "$rootfs_backup/"
    
    info "Unmounting original rootfs..."
    umount "$MOUNT_ORIG"
    
    info "Creating LUKS2 encrypted container with cipher: $cipher"
    
    # Format with LUKS using keyfile (no passphrase prompt)
    cryptsetup luksFormat \
        --type luks2 \
        --cipher "$cipher" \
        --hash sha256 \
        --iter-time 5000 \
        --key-size 256 \
        --pbkdf argon2i \
        --batch-mode \
        --key-file "$keyfile" \
        "$root_part"
    
    # Optionally add passphrase as second key
    if [ "$keep_passphrase" = "yes" ]; then
        info "Adding passphrase as additional unlock method..."
        echo "Enter passphrase for encrypted rootfs:"
        cryptsetup luksAddKey --key-file "$keyfile" "$root_part"
    fi
    
    info "Opening LUKS container..."
    CRYPT_NAME="${mapper_name}_$$"
    cryptsetup luksOpen --key-file "$keyfile" "$root_part" "$CRYPT_NAME"
    
    local crypt_dev="/dev/mapper/$CRYPT_NAME"
    
    info "Creating ext4 filesystem on encrypted container..."
    mkfs.ext4 -F -L "rootfs" "$crypt_dev"
    
    info "Mounting encrypted rootfs..."
    mount "$crypt_dev" "$MOUNT_ENCRYPTED"
    
    info "Restoring rootfs content to encrypted partition..."
    rsync -aHAXx --info=progress2 "$rootfs_backup/" "$MOUNT_ENCRYPTED/"
    
    info "Mounting boot partition..."
    mount "$boot_part" "$MOUNT_BOOT"
    
    info "Configuring boot for encrypted rootfs..."
    configure_boot "$MOUNT_BOOT" "$MOUNT_ENCRYPTED" "$root_part" "$mapper_name" "$keyfile"
    
    info "Syncing filesystems..."
    sync
    
    info "Unmounting partitions..."
    umount "$MOUNT_BOOT"
    umount "$MOUNT_ENCRYPTED"
    
    info "Closing LUKS container..."
    cryptsetup luksClose "$CRYPT_NAME"
    CRYPT_NAME=""
    
    info "Detaching loop device..."
    losetup -d "$LOOP_DEV"
    LOOP_DEV=""
    
    info "Cleaning up temporary files..."
    rm -rf "$WORK_DIR"
    WORK_DIR=""
}

function configure_boot() {
    local boot_mount="$1"
    local root_mount="$2"
    local root_part="$3"
    local mapper_name="$4"
    local keyfile="$5"
    
    local cmdline_file=""
    local keyfile_name
    keyfile_name=$(basename "$keyfile")
    
    # Find cmdline.txt (RasPiOS/Buildroot location may vary)
    if [ -f "${boot_mount}/cmdline.txt" ]; then
        cmdline_file="${boot_mount}/cmdline.txt"
    elif [ -f "${boot_mount}/firmware/cmdline.txt" ]; then
        cmdline_file="${boot_mount}/firmware/cmdline.txt"
    fi
    
    if [ -n "$cmdline_file" ]; then
        info "Updating cmdline.txt for encrypted rootfs..."
        
        # Backup original
        cp "$cmdline_file" "${cmdline_file}.orig"
        
        # Get current root parameter
        local current_root
        current_root=$(grep -oP 'root=\S+' "$cmdline_file" | head -1)
        
        # Build new cmdline
        local new_cmdline
        new_cmdline=$(cat "$cmdline_file")
        
        # Replace root= with /dev/mapper/cryptroot
        new_cmdline=$(echo "$new_cmdline" | sed "s|root=[^ ]*|root=/dev/mapper/${mapper_name}|")
        
        # Add cryptdevice parameter if not present
        if ! echo "$new_cmdline" | grep -q "cryptdevice="; then
            # Use PARTUUID of the root partition for cryptdevice
            local partuuid
            partuuid=$(blkid -s PARTUUID -o value "$root_part" 2>/dev/null || echo "")
            
            if [ -n "$partuuid" ]; then
                new_cmdline="${new_cmdline} cryptdevice=PARTUUID=${partuuid}:${mapper_name}"
            else
                new_cmdline="${new_cmdline} cryptdevice=${root_part}:${mapper_name}"
            fi
        fi
        
        # Add luks.crypttab=no to prevent systemd-cryptsetup-generator issues
        if ! echo "$new_cmdline" | grep -q "luks.crypttab=no"; then
            new_cmdline="${new_cmdline} luks.crypttab=no"
        fi
        
        # Add keyfile name for initramfs USB search
        if ! echo "$new_cmdline" | grep -q "luks.keyfile="; then
            new_cmdline="${new_cmdline} luks.keyfile=${keyfile_name}"
        fi
        
        echo "$new_cmdline" > "$cmdline_file"
        info "New cmdline: $new_cmdline"
    fi
    
    # Update fstab
    info "Updating /etc/fstab..."
    local fstab="${root_mount}/etc/fstab"
    if [ -f "$fstab" ]; then
        sed -i "s|^[^#].*[[:space:]]/[[:space:]]|/dev/mapper/${mapper_name} / |" "$fstab"
    fi
    
    # NOTE: Keyfile is NOT stored in rootfs for security
    # USB key is REQUIRED - keyfile name is passed via cmdline (luks.keyfile=)
}


#
# Main script
#

# Default values
INPUT_IMG=""
OUTPUT_IMG=""
KEYFILE=""
KEYDIR="./keys"
MAPPER_NAME="cryptroot"
CRYPTO="aes"
NO_BACKUP=0
KEEP_PASSPHRASE="no"

# Cleanup variables
LOOP_DEV=""
WORK_DIR=""
MOUNT_ORIG=""
MOUNT_BOOT=""
MOUNT_ENCRYPTED=""
CRYPT_NAME=""
CLEANUP_DONE=0

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --keyfile)
            KEYFILE="$2"
            shift 2
            ;;
        --keydir)
            KEYDIR="$2"
            shift 2
            ;;
        --mapper)
            MAPPER_NAME="$2"
            shift 2
            ;;
        --crypto)
            CRYPTO="$2"
            shift 2
            ;;
        --no-backup)
            NO_BACKUP=1
            shift
            ;;
        --keep-passphrase)
            KEEP_PASSPHRASE="yes"
            shift
            ;;
        --help|-h)
            printhelp
            ;;
        -*)
            errexit "Unknown option: $1"
            ;;
        *)
            if [ -z "$INPUT_IMG" ]; then
                INPUT_IMG="$1"
            elif [ -z "$OUTPUT_IMG" ]; then
                OUTPUT_IMG="$1"
            else
                errexit "Too many arguments"
            fi
            shift
            ;;
    esac
done

# Validate arguments
[ -z "$INPUT_IMG" ] && printhelp
[ ! -f "$INPUT_IMG" ] && errexit "Input image not found: $INPUT_IMG"
[ -z "$OUTPUT_IMG" ] && OUTPUT_IMG="${INPUT_IMG%.img}-encrypted.img"

# Trap for cleanup on exit
trap cleanup EXIT

# Check requirements
check_requirements

info "Input image: $INPUT_IMG"
info "Output image: $OUTPUT_IMG"
info "Mapper name: $MAPPER_NAME"
info "Crypto: $CRYPTO"

# Generate or use existing keyfile
if [ -z "$KEYFILE" ]; then
    info "Generating unique keyfile..."
    KEYFILE=$(generate_keyfile "$KEYDIR")
fi

[ ! -f "$KEYFILE" ] && errexit "Keyfile not found: $KEYFILE"
info "Keyfile: $KEYFILE"

# Perform encryption
encrypt_image "$INPUT_IMG" "$OUTPUT_IMG" "$KEYFILE" "$MAPPER_NAME" "$CRYPTO" "$KEEP_PASSPHRASE"

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Encryption complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Encrypted image: $OUTPUT_IMG"
echo "Keyfile: $KEYFILE"
echo ""
echo "To prepare USB key disk:"
echo "  1. Format USB drive with FAT32"
echo "  2. Copy $(basename "$KEYFILE") to the USB drive"
echo ""
echo "To burn image:"
echo "  dd if=$OUTPUT_IMG of=/dev/sdX bs=4M status=progress"
echo ""

