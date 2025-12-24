#!/bin/bash
#
# raspios-pre-burn-encrypt.sh - Encrypt Raspberry Pi OS image BEFORE burning to SD card
#
# This script takes a standard Raspberry Pi OS .img file and creates an encrypted version
# with a unique LUKS keyfile for USB key-based unlock.
#
# Usage: ./raspios-pre-burn-encrypt.sh input.img [output.img] [--keyfile /path/to/key]
#
# Requirements:
#   - cryptsetup
#   - parted
#   - kpartx (or losetup with partition support)
#   - e2fsprogs (resize2fs, mkfs.ext4)
#   - qemu-user-static (for ARM chroot)
#   - debootstrap or ability to install packages in chroot
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

function errexit() {
    echo -e "${RED}Error: $1${NC}" >&2
    exit 1
}

function info() {
    echo -e "${GREEN}> $1${NC}"
}

function warn() {
    echo -e "${YELLOW}Warning: $1${NC}"
}

function cleanup() {
    [ "${CLEANUP_DONE:-0}" -eq 1 ] && return 0
    CLEANUP_DONE=1
    
    set +e
    
    echo "> Cleaning up..." >&2
    
    # First, unmount chroot bind mounts (in reverse order)
    if [ -n "$CHROOT_DIR" ] && [ -d "$CHROOT_DIR" ]; then
        umount "${CHROOT_DIR}/dev/pts" 2>/dev/null || true
        umount "${CHROOT_DIR}/dev" 2>/dev/null || true
        umount "${CHROOT_DIR}/sys" 2>/dev/null || true
        umount "${CHROOT_DIR}/proc" 2>/dev/null || true
        # Also unmount boot if it was mounted inside chroot
        umount "${CHROOT_DIR}/boot/firmware" 2>/dev/null || true
        umount "${CHROOT_DIR}/boot" 2>/dev/null || true
    fi
    
    # Unmount main mounts
    [ -n "$MOUNT_BOOT" ] && [ -d "$MOUNT_BOOT" ] && mountpoint -q "$MOUNT_BOOT" && umount "$MOUNT_BOOT" 2>/dev/null || true
    [ -n "$MOUNT_ENCRYPTED" ] && [ -d "$MOUNT_ENCRYPTED" ] && mountpoint -q "$MOUNT_ENCRYPTED" && umount "$MOUNT_ENCRYPTED" 2>/dev/null || true
    [ -n "$MOUNT_ORIG" ] && [ -d "$MOUNT_ORIG" ] && mountpoint -q "$MOUNT_ORIG" && umount "$MOUNT_ORIG" 2>/dev/null || true
    
    # Close LUKS
    if [ -n "$CRYPT_NAME" ]; then
        cryptsetup status "$CRYPT_NAME" &>/dev/null && cryptsetup luksClose "$CRYPT_NAME" 2>/dev/null || true
    fi
    
    # Detach loop devices
    [ -n "$LOOP_DEV" ] && losetup -d "$LOOP_DEV" 2>/dev/null || true
    
    # Remove temp directories
    [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ] && rm -rf "$WORK_DIR" 2>/dev/null || true
    
    set -e
}

trap cleanup EXIT

function printhelp() {
    cat << 'EOF'
raspios-pre-burn-encrypt.sh - Encrypt Raspberry Pi OS image before burning

USAGE:
    sudo ./raspios-pre-burn-encrypt.sh [OPTIONS] input.img [output.img]

OPTIONS:
    --keyfile PATH      Use existing keyfile (default: generate new UUID-based key)
    --keydir PATH       Directory to store generated keyfiles (default: ./keys)
    --mapper NAME       Mapper name for encrypted rootfs (default: cryptroot)
    --crypto TYPE       Encryption type: aes or xchacha (default: aes for Pi5)
    --no-backup         Don't create backup of rootfs (faster but less safe)
    --keep-passphrase   Also enable passphrase unlock (default: keyfile only)
    --ssh               Enable SSH unlock in initramfs (requires --authorized-keys)
    --authorized-keys   SSH public key file for initramfs unlock
    --help              Show this help

EXAMPLES:
    # Basic usage - generates unique keyfile
    sudo ./raspios-pre-burn-encrypt.sh 2025-12-04-raspios-trixie-arm64-lite.img encrypted.img

    # Use existing keyfile
    sudo ./raspios-pre-burn-encrypt.sh --keyfile /path/to/mykey.lek raspios.img

    # With SSH unlock support
    sudo ./raspios-pre-burn-encrypt.sh --ssh --authorized-keys ~/.ssh/id_rsa.pub raspios.img

NOTES:
    - Requires root privileges
    - Output image will be same size as input
    - Keyfile is saved to --keydir with UUID name
    - For USB key unlock, copy the .lek file to FAT32 USB drive
    - Raspberry Pi OS uses update-initramfs (Debian/Ubuntu style)
    
EOF
    exit 0
}

function generate_uuid() {
    local uuid=""
    
    if command -v uuidgen &>/dev/null; then
        uuid=$(uuidgen 2>/dev/null)
        [ -n "$uuid" ] && echo "$uuid" && return 0
    fi
    
    if [ -r /proc/sys/kernel/random/uuid ]; then
        uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null)
        [ -n "$uuid" ] && echo "$uuid" && return 0
    fi
    
    if command -v openssl &>/dev/null; then
        uuid=$(openssl rand -hex 16 | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/' 2>/dev/null)
        [ -n "$uuid" ] && echo "$uuid" && return 0
    fi
    
    uuid=$(dd if=/dev/urandom bs=1 count=16 2>/dev/null | od -An -tx1 | tr -d ' \n' | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/')
    [ -n "$uuid" ] && echo "$uuid" && return 0
    
    return 1
}

function check_requirements() {
    local missing=()
    
    for cmd in cryptsetup parted losetup mkfs.ext4 resize2fs dd; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        errexit "Missing required commands: ${missing[*]}\nInstall with: apt install cryptsetup parted e2fsprogs"
    fi
    
    # Check for qemu-user-static (needed for ARM chroot)
    if ! command -v qemu-aarch64-static &>/dev/null && ! command -v qemu-arm-static &>/dev/null; then
        warn "qemu-user-static not found. Installing..."
        apt-get install -y qemu-user-static || errexit "Failed to install qemu-user-static"
    fi
    
    if [ "$EUID" -ne 0 ]; then
        errexit "This script must be run as root"
    fi
}

function generate_keyfile() {
    local keydir="$1"
    local keyuuid
    
    keyuuid=$(generate_uuid)
    
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

function setup_loop_device() {
    local img="$1"
    losetup --find --show --partscan "$img"
}

function get_loop_partition() {
    local loop="$1"
    local partnum="$2"
    
    if [ -b "${loop}p${partnum}" ]; then
        echo "${loop}p${partnum}"
    elif [ -b "${loop}${partnum}" ]; then
        echo "${loop}${partnum}"
    else
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

function find_boot_partition() {
    local root_mount="$1"
    
    # Try new Raspberry Pi OS location first
    if [ -d "${root_mount}/boot/firmware" ]; then
        echo "${root_mount}/boot/firmware"
        return 0
    fi
    
    # Try old location
    if [ -d "${root_mount}/boot" ]; then
        echo "${root_mount}/boot"
        return 0
    fi
    
    errexit "Cannot find boot partition in chroot"
}

function setup_chroot() {
    local root_mount="$1"
    
    info "Setting up chroot environment..."
    
    # Mount essential filesystems
    mount -t proc none "${root_mount}/proc" 2>/dev/null || true
    mount -t sysfs none "${root_mount}/sys" 2>/dev/null || true
    mount -o bind /dev "${root_mount}/dev" 2>/dev/null || true
    mount -o bind /dev/pts "${root_mount}/dev/pts" 2>/dev/null || true
    
    # Copy qemu for ARM emulation
    local qemu_binary=""
    if [ -f /usr/bin/qemu-aarch64-static ]; then
        qemu_binary="/usr/bin/qemu-aarch64-static"
    elif [ -f /usr/bin/qemu-arm-static ]; then
        qemu_binary="/usr/bin/qemu-arm-static"
    fi
    
    if [ -n "$qemu_binary" ]; then
        mkdir -p "${root_mount}/usr/bin"
        cp "$qemu_binary" "${root_mount}/usr/bin/"
    fi
    
    # Setup DNS for chroot
    if [ -f /etc/resolv.conf ]; then
        cp /etc/resolv.conf "${root_mount}/etc/resolv.conf"
    fi
}

function cleanup_chroot() {
    local root_mount="$1"
    
    info "Cleaning up chroot environment..."
    
    # Unmount in reverse order
    umount "${root_mount}/dev/pts" 2>/dev/null || true
    umount "${root_mount}/dev" 2>/dev/null || true
    umount "${root_mount}/sys" 2>/dev/null || true
    umount "${root_mount}/proc" 2>/dev/null || true
    
    # Remove qemu binary
    rm -f "${root_mount}/usr/bin/qemu-aarch64-static" 2>/dev/null || true
    rm -f "${root_mount}/usr/bin/qemu-arm-static" 2>/dev/null || true
}

function install_packages_in_chroot() {
    local root_mount="$1"
    local enable_ssh="$2"
    
    info "Installing required packages in chroot..."
    
    # Core packages: initramfs-tools is essential for Raspberry Pi OS
    # cryptsetup-initramfs pulls in cryptsetup automatically
    local packages="initramfs-tools cryptsetup-initramfs cryptsetup-bin"
    if [ "$enable_ssh" = "yes" ]; then
        packages="$packages dropbear-initramfs dropbear-bin"
    fi
    
    # Use chroot to install packages
    # Note: We need to handle the case where apt update might fail in chroot without network
    chroot "$root_mount" /bin/bash << EOF
set -e
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
export LANG=C

echo "> Checking for required packages..."

# First, check if packages are already installed
NEED_INSTALL=0
for pkg in initramfs-tools cryptsetup-initramfs; do
    if ! dpkg -l \$pkg 2>/dev/null | grep -q "^ii"; then
        echo "  Package \$pkg needs installation"
        NEED_INSTALL=1
    else
        echo "  Package \$pkg is already installed"
    fi
done

if [ \$NEED_INSTALL -eq 1 ]; then
    echo "> Attempting to install packages..."
    
    # Try to update package lists (may fail if no network, but packages might be cached)
    apt-get update 2>/dev/null || {
        echo "Warning: apt-get update failed (no network?), trying with cached packages..."
    }
    
    # Install packages
    apt-get install -y --no-install-recommends $packages 2>&1 || {
        echo "Warning: apt-get install had issues"
    }
fi

# Verify critical packages are installed
echo "> Verifying critical packages..."
MISSING=""
for pkg in initramfs-tools cryptsetup-initramfs cryptsetup-bin; do
    if ! dpkg -l \$pkg 2>/dev/null | grep -q "^ii"; then
        MISSING="\$MISSING \$pkg"
    fi
done

if [ -n "\$MISSING" ]; then
    echo "ERROR: Missing critical packages:\$MISSING"
    echo "The following packages must be installed for LUKS encryption to work:"
    echo "  - initramfs-tools: Required for generating initramfs"
    echo "  - cryptsetup-initramfs: Required for LUKS support in initramfs"
    echo "  - cryptsetup-bin: Required for cryptsetup utility"
    echo ""
    echo "If apt failed, you may need to:"
    echo "  1. Ensure the image has network access, or"
    echo "  2. Pre-install these packages before encryption"
    exit 1
fi

echo "> All required packages are available"
EOF
    
    if [ $? -ne 0 ]; then
        errexit "Critical packages are missing and could not be installed. Cannot proceed."
    fi
}

function create_initramfs_hooks() {
    local root_mount="$1"
    local keyfile_name="$2"
    local mapper_name="$3"
    local crypto="$4"
    
    info "Creating initramfs hooks for LUKS..."
    
    # Create hook directory
    mkdir -p "${root_mount}/etc/initramfs-tools/hooks"
    mkdir -p "${root_mount}/etc/initramfs-tools/scripts/local-bottom"
    
    # Store mapper name and keyfile for initramfs use
    echo "$mapper_name" > "${root_mount}/etc/mappername"
    echo "$crypto" > "${root_mount}/etc/sdmcrypto"
    echo "$keyfile_name" > "${root_mount}/etc/sdmkeyfile"
    
    # Create LUKS hook (similar to sdm's luks-hooks)
    cat > "${root_mount}/etc/initramfs-tools/hooks/luks-hooks" << 'HOOKEOF'
#!/bin/sh -e
PREREQS=""
case "$1" in
    prereqs) echo "${PREREQS}"; exit 0;;
esac

. /usr/share/initramfs-tools/hook-functions

# Copy cryptsetup (may already be copied by cryptsetup-initramfs, but ensure it's there)
copy_exec /usr/sbin/cryptsetup /usr/sbin || true

# Copy bash (needed for sdmluksunlock)
copy_exec /usr/bin/bash /usr/bin || true

# Copy the unlock script
copy_file text /usr/bin/sdmluksunlock /usr/bin/sdmluksunlock || true

# Copy configuration files
copy_file text /etc/mappername /etc/mappername || true
copy_file text /etc/sdmcrypto /etc/sdmcrypto || true
copy_file text /etc/sdmkeyfile /etc/sdmkeyfile || true

HOOKEOF
    
    # Add keyfile copy if specified
    if [ -n "$keyfile_name" ]; then
        cat >> "${root_mount}/etc/initramfs-tools/hooks/luks-hooks" << EOF
# Copy keyfile reference (actual keyfile is on USB drive)
copy_file text /etc/sdm/assets/cryptroot/$keyfile_name /etc/$keyfile_name 2>/dev/null || true
EOF
    fi
    
    cat >> "${root_mount}/etc/initramfs-tools/hooks/luks-hooks" << 'HOOKEOF'
exit 0
HOOKEOF
    
    chmod 755 "${root_mount}/etc/initramfs-tools/hooks/luks-hooks"
    
    # Create USB keyfile unlock script (similar to sdm's sdmluksunlock)
    mkdir -p "${root_mount}/usr/bin"
    cat > "${root_mount}/usr/bin/sdmluksunlock" << 'UNLOCKEOF'
#!/bin/bash
#
# USB keyfile unlock script for initramfs
#
trydisks()
{
    local kfn="$1"
    echo "" >/dev/console
    echo "> sdmluksunlock: Looking for USB disk with luks Key file '${kfn}'" >/dev/console
    echo "" >/dev/console
    
    while :; do
        sleep 1
        for usbpartition in /dev/sd?1 /dev/mmcblk?p1; do
            [ -b "$usbpartition" ] || continue
            usbdevice=$(readlink -f "$usbpartition" 2>/dev/null || echo "$usbpartition")
            
            if mount -t vfat "$usbdevice" /mnt 2>/dev/null; then
                echo "> Mounted disk $usbdevice" >/dev/console
                if [ -e "/mnt/$kfn" ]; then
                    echo "> Found Key file '$kfn'" >/dev/console
                    echo "> Unlocking rootfs" >/dev/console
                    cat "/mnt/$kfn"
                    umount "$usbdevice" >/dev/null 2>&1 || true
                    echo "> sdmluksunlock: Kill askpass; Ignore 'Killed' message" >/dev/console
                    aps=$(ps e | grep askpass | grep -v grep | awk '{print $1}' 2>/dev/null || true)
                    [ "$aps" != "" ] && kill -KILL $aps >/dev/null 2>/dev/null || true
                    exit 0
                else
                    echo "% sdmluksunlock: Key '${kfn%.lek}' not found on this disk" >/dev/console
                    umount "$usbdevice" >/dev/null 2>&1 || true
                fi
            fi
        done
    done
    return 0
}

set -e
mkdir -p /mnt

kfn=""
if [ -n "$CRYPTTAB_KEY" ]; then
    kfn=$(basename "$CRYPTTAB_KEY")
    kfn=${kfn%.lek}.lek
fi

if [ -n "$kfn" ]; then
    if [ "$2" = "trydisks" ]; then
        touch /tmp/ftrydisk
        trydisks "$kfn"
        exit 0
    else
        [ ! -f /tmp/ftrydisk ] && ( "$0" "$CRYPTTAB_KEY" trydisks </dev/null & )
    fi
fi

echo "" >/dev/console
/lib/cryptsetup/askpass "Insert USB Keyfile Disk or type passphrase then press ENTER:"
aps=$(ps e | grep trydisks | grep -v grep | awk '{print $1}' 2>/dev/null || true)
[ "$aps" != "" ] && kill -KILL $aps >/dev/null 2>/dev/null || true
exit 0
UNLOCKEOF
    
    chmod 755 "${root_mount}/usr/bin/sdmluksunlock"
    
    # Copy keyfile to chroot if specified
    if [ -n "$keyfile_name" ] && [ -f "$KEYFILE" ]; then
        mkdir -p "${root_mount}/etc/sdm/assets/cryptroot"
        cp "$KEYFILE" "${root_mount}/etc/sdm/assets/cryptroot/$keyfile_name"
    fi
    
    # Configure initramfs modules for crypto
    info "Configuring initramfs modules for crypto: $crypto"
    case "$crypto" in
        xchacha)
            cat >> "${root_mount}/etc/initramfs-tools/modules" << EOF
algif_skcipher
xchacha20
adiantum
aes_arm
sha256
nhpoly1305
dm-crypt
EOF
            ;;
        aes|aes-*)
            cat >> "${root_mount}/etc/initramfs-tools/modules" << EOF
algif_skcipher
aes_arm64
aes_ce_blk
aes_ce_ccm
aes_ce_cipher
sha256_arm64
cbc
dm-crypt
EOF
            ;;
    esac
    
    # Update initramfs configuration
    sed -i "s/^MODULES=dep/MODULES=most/" "${root_mount}/etc/initramfs-tools/initramfs.conf" 2>/dev/null || true
    sed -i "s/^KEYMAP=n/KEYMAP=y/" "${root_mount}/etc/initramfs-tools/initramfs.conf" 2>/dev/null || true
}

function configure_ssh_initramfs() {
    local root_mount="$1"
    local auth_keys_file="$2"
    
    if [ -z "$auth_keys_file" ] || [ ! -f "$auth_keys_file" ]; then
        return 1
    fi
    
    info "Configuring SSH in initramfs..."
    
    # Copy authorized keys
    mkdir -p "${root_mount}/etc/dropbear/initramfs"
    cp "$auth_keys_file" "${root_mount}/etc/dropbear/initramfs/authorized_keys"
    
    # Configure dropbear
    cat > "${root_mount}/etc/dropbear/initramfs/dropbear.conf" << EOF
DROPBEAR_OPTIONS="-I 3600 -j -k -s -p 22 -c bash -r /etc/dropbear/dropbear_ed25519_host_key"
EOF
    
    # Convert SSH host key if available
    if [ -f "${root_mount}/etc/ssh/ssh_host_ed25519_key" ]; then
        chroot "$root_mount" dropbearconvert openssh dropbear \
            /etc/ssh/ssh_host_ed25519_key \
            /etc/dropbear/initramfs/dropbear_ed25519_host_key 2>/dev/null || true
    fi
}

function update_initramfs() {
    local root_mount="$1"
    
    info "Updating initramfs in chroot..."
    
    # Update initramfs using chroot
    # We need to find the kernel version and generate initramfs for it
    chroot "$root_mount" /bin/bash << 'EOF'
set -e
export LC_ALL=C
export LANG=C

# Find the kernel version(s) installed
# Raspberry Pi OS typically has kernels in /lib/modules/
echo "> Looking for installed kernels..."
KERNEL_VERSIONS=""
for kdir in /lib/modules/*; do
    if [ -d "$kdir" ]; then
        kver=$(basename "$kdir")
        echo "  Found kernel: $kver"
        KERNEL_VERSIONS="$KERNEL_VERSIONS $kver"
    fi
done

# Update initramfs for all kernels
if [ -n "$KERNEL_VERSIONS" ]; then
    for kver in $KERNEL_VERSIONS; do
        echo "> Generating initramfs for kernel $kver..."
        update-initramfs -c -k "$kver" 2>&1 || {
            echo "Warning: Failed to create initramfs for $kver, trying update..."
            update-initramfs -u -k "$kver" 2>&1 || true
        }
    done
else
    echo "> No specific kernel found, using update-initramfs -u..."
    update-initramfs -u 2>&1 || true
fi

# Find the boot directory (Bookworm uses /boot/firmware, older uses /boot)
BOOT_DIR=""
if [ -d /boot/firmware ] && mountpoint -q /boot/firmware 2>/dev/null; then
    BOOT_DIR="/boot/firmware"
elif mountpoint -q /boot 2>/dev/null; then
    BOOT_DIR="/boot"
else
    BOOT_DIR="/boot/firmware"  # Default for newer Raspberry Pi OS
fi

# Verify initramfs was created and copy to boot partition if needed
echo "> Checking for initramfs files..."
INITRD_FOUND=""

# Check in /boot first
for f in /boot/initrd.img-* /boot/initrd.img; do
    if [ -f "$f" ]; then
        echo "  Found: $f"
        INITRD_FOUND="$f"
        # Copy to boot partition if different location
        if [ "$BOOT_DIR" != "/boot" ] && [ -d "$BOOT_DIR" ]; then
            echo "  Copying to $BOOT_DIR..."
            cp "$f" "$BOOT_DIR/" 2>/dev/null || true
        fi
    fi
done

# Also check in boot directory
for f in ${BOOT_DIR}/initrd.img-* ${BOOT_DIR}/initrd.img; do
    if [ -f "$f" ]; then
        echo "  Found: $f"
        INITRD_FOUND="$f"
    fi
done

if [ -z "$INITRD_FOUND" ]; then
    echo "WARNING: No initramfs found! This may cause boot failure."
    echo "  Expected locations: /boot/initrd.img* or $BOOT_DIR/initrd.img*"
else
    echo "> Initramfs ready: $(basename "$INITRD_FOUND")"
fi
EOF
    
    if [ $? -ne 0 ]; then
        warn "Initramfs update may have issues, but continuing..."
    fi
}

function configure_boot_and_crypttab() {
    local boot_mount="$1"
    local root_mount="$2"
    local root_part="$3"
    local mapper_name="$4"
    local keyfile_name="$5"
    
    info "Configuring boot parameters and crypttab..."
    
    # Find cmdline.txt and config.txt
    local cmdline_file=""
    local config_file=""
    
    if [ -f "${boot_mount}/cmdline.txt" ]; then
        cmdline_file="${boot_mount}/cmdline.txt"
        config_file="${boot_mount}/config.txt"
    elif [ -f "${boot_mount}/firmware/cmdline.txt" ]; then
        cmdline_file="${boot_mount}/firmware/cmdline.txt"
        config_file="${boot_mount}/firmware/config.txt"
    fi
    
    if [ -n "$cmdline_file" ]; then
        info "Updating cmdline.txt..."
        
        # Backup original
        cp "$cmdline_file" "${cmdline_file}.orig"
        
        # Get PARTUUID
        local partuuid
        partuuid=$(blkid -s PARTUUID -o value "$root_part" 2>/dev/null || echo "")
        
        # Update root parameter
        local new_cmdline
        new_cmdline=$(cat "$cmdline_file")
        
        # Replace root= with /dev/mapper/cryptroot
        new_cmdline=$(echo "$new_cmdline" | sed "s|root=[^ ]*|root=/dev/mapper/${mapper_name}|")
        
        # Add cryptdevice if not present
        if ! echo "$new_cmdline" | grep -q "cryptdevice="; then
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
        
        # Add rw flag for encrypted rootfs
        if ! echo "$new_cmdline" | grep -q " rw "; then
            new_cmdline="${new_cmdline} rw"
        fi
        
        # Add keyfile name if specified
        if [ -n "$keyfile_name" ] && ! echo "$new_cmdline" | grep -q "luks.keyfile="; then
            new_cmdline="${new_cmdline} luks.keyfile=${keyfile_name}"
        fi
        
        # Remove 'quiet' and 'splash' for visibility during encryption unlock
        new_cmdline=$(echo "$new_cmdline" | sed 's/ quiet//g; s/ splash//g')
        
        echo "$new_cmdline" > "$cmdline_file"
        info "Updated cmdline: $new_cmdline"
    fi
    
    # CRITICAL: Update config.txt to load initramfs
    # Without this, the Raspberry Pi will NOT load the initramfs and boot will fail!
    if [ -n "$config_file" ] && [ -f "$config_file" ]; then
        info "Updating config.txt to load initramfs..."
        
        # Backup original
        cp "$config_file" "${config_file}.orig"
        
        # Find the initramfs file name
        # Raspberry Pi OS creates initrd.img-<version> or initramfs-<version>
        local initramfs_name=""
        local initramfs_source=""
        
        # Look for initramfs in the boot mount first
        info "Searching for initramfs files..."
        for pattern in "${boot_mount}/initrd.img"-* "${boot_mount}/initrd.img" \
                       "${boot_mount}/initramfs"-* "${boot_mount}/initramfs.img"; do
            if [ -f "$pattern" ]; then
                initramfs_name=$(basename "$pattern")
                initramfs_source="$pattern"
                info "  Found on boot partition: $initramfs_name"
                break
            fi
        done
        
        # If not found on boot, look in rootfs /boot directory
        if [ -z "$initramfs_name" ]; then
            for pattern in "${root_mount}/boot/initrd.img"-* "${root_mount}/boot/initrd.img" \
                           "${root_mount}/boot/initramfs"-* "${root_mount}/boot/initramfs.img"; do
                if [ -f "$pattern" ]; then
                    initramfs_name=$(basename "$pattern")
                    initramfs_source="$pattern"
                    info "  Found in rootfs: $initramfs_name"
                    # Copy to boot partition
                    info "  Copying to boot partition..."
                    cp "$pattern" "${boot_mount}/${initramfs_name}"
                    break
                fi
            done
        fi
        
        # Also check in /boot/firmware inside rootfs (for Bookworm+)
        if [ -z "$initramfs_name" ]; then
            for pattern in "${root_mount}/boot/firmware/initrd.img"-* "${root_mount}/boot/firmware/initrd.img"; do
                if [ -f "$pattern" ]; then
                    initramfs_name=$(basename "$pattern")
                    initramfs_source="$pattern"
                    info "  Found in rootfs/boot/firmware: $initramfs_name"
                    break
                fi
            done
        fi
        
        if [ -n "$initramfs_name" ]; then
            # Remove any existing initramfs line
            sed -i '/^initramfs /d' "$config_file"
            
            # Add initramfs line - use 'followkernel' to let the bootloader figure out the address
            echo "initramfs ${initramfs_name} followkernel" >> "$config_file"
            info "Added to config.txt: initramfs ${initramfs_name} followkernel"
            
            # List config.txt for verification
            info "Current config.txt entries related to boot:"
            grep -E "^(initramfs|kernel|arm_64bit)" "$config_file" || true
        else
            warn "No initramfs file found! This is a critical error."
            warn "Attempting to create a generic entry, but boot may fail!"
            warn "Locations searched:"
            warn "  - ${boot_mount}/initrd.img*"
            warn "  - ${root_mount}/boot/initrd.img*"
            warn "  - ${root_mount}/boot/firmware/initrd.img*"
            
            # List what's actually in the boot mount
            info "Files on boot partition:"
            ls -la "${boot_mount}/" | head -20 || true
            
            # Try to add a generic entry anyway
            echo "initramfs initrd.img followkernel" >> "$config_file"
            warn "Added generic entry: initramfs initrd.img followkernel"
        fi
    else
        warn "config.txt not found at ${config_file}! Boot configuration incomplete."
    fi
    
    # Update fstab
    info "Updating /etc/fstab..."
    local fstab="${root_mount}/etc/fstab"
    if [ -f "$fstab" ]; then
        # Backup original
        cp "$fstab" "${fstab}.orig"
        # Replace the root mount point
        sed -i "s|^PARTUUID=[^ ]*[[:space:]]*/[[:space:]]|/dev/mapper/${mapper_name} / |" "$fstab"
        # Also handle UUID format
        sed -i "s|^UUID=[^ ]*[[:space:]]*/[[:space:]]|/dev/mapper/${mapper_name} / |" "$fstab"
        info "Updated fstab for encrypted rootfs"
    fi
    
    # Update crypttab
    info "Updating /etc/crypttab..."
    local crypttab="${root_mount}/etc/crypttab"
    local kfuuid="none"
    local kfu=""
    local ktries=""
    
    if [ -n "$keyfile_name" ]; then
        kfuuid="${keyfile_name%.lek}"
        kfu=",keyscript=/usr/bin/sdmluksunlock"
        ktries=",tries=0"  # Infinite tries for USB key
    fi
    
    # Get rootfs device identifier
    local root_identifier
    root_identifier=$(blkid -s PARTUUID -o value "$root_part" 2>/dev/null || echo "")
    
    if [ -n "$root_identifier" ]; then
        root_identifier="PARTUUID=${root_identifier}"
    else
        root_identifier="$root_part"
    fi
    
    # Create or append to crypttab
    echo "${mapper_name}	${root_identifier} ${kfuuid} luks,discard${ktries}${kfu}" >> "$crypttab"
    info "Updated crypttab entry: ${mapper_name}	${root_identifier} ${kfuuid} luks,discard${ktries}${kfu}"
}

function encrypt_image() {
    local input_img="$1"
    local output_img="$2"
    local keyfile="$3"
    local mapper_name="$4"
    local crypto="$5"
    local keep_passphrase="$6"
    local enable_ssh="$7"
    local auth_keys_file="$8"
    
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
    
    if [ "$input_img" != "$output_img" ]; then
        cp "$input_img" "$output_img"
    fi
    
    info "Setting up loop device for image..."
    LOOP_DEV=$(setup_loop_device "$output_img")
    info "Loop device: $LOOP_DEV"
    
    local boot_part root_part
    boot_part=$(get_loop_partition "$LOOP_DEV" 1)
    root_part=$(get_loop_partition "$LOOP_DEV" 2)
    
    info "Boot partition: $boot_part"
    info "Root partition: $root_part"
    
    WORK_DIR=$(mktemp -d)
    MOUNT_ORIG="${WORK_DIR}/orig_root"
    MOUNT_BOOT="${WORK_DIR}/boot"
    MOUNT_ENCRYPTED="${WORK_DIR}/encrypted_root"
    CHROOT_DIR="${WORK_DIR}/chroot"
    local rootfs_backup="${WORK_DIR}/rootfs_backup"
    
    mkdir -p "$MOUNT_ORIG" "$MOUNT_BOOT" "$MOUNT_ENCRYPTED" "$CHROOT_DIR" "$rootfs_backup"
    
    info "Mounting original rootfs..."
    mount "$root_part" "$MOUNT_ORIG"
    
    info "Backing up rootfs content..."
    rsync -aHAXx --info=progress2 "$MOUNT_ORIG/" "$rootfs_backup/"
    
    info "Unmounting original rootfs..."
    umount "$MOUNT_ORIG"
    
    info "Creating LUKS2 encrypted container with cipher: $cipher"
    
    cryptsetup luksFormat \
        --type luks2 \
        --cipher "$cipher" \
        --hash sha256 \
        --iter-time 1000 \
        --key-size 256 \
        --pbkdf pbkdf2 \
        --batch-mode \
        --key-file "$keyfile" \
        "$root_part"
    
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
    
    # Setup chroot
    CHROOT_DIR="$MOUNT_ENCRYPTED"
    setup_chroot "$CHROOT_DIR"
    
    # Mount boot partition inside chroot (needed for update-initramfs)
    # Raspberry Pi OS Bookworm+ uses /boot/firmware, older versions use /boot
    info "Mounting boot partition inside chroot..."
    mount "$boot_part" "$MOUNT_BOOT"
    
    # Determine where boot should be mounted in chroot
    local chroot_boot_dir
    if [ -d "${CHROOT_DIR}/boot/firmware" ]; then
        # Raspberry Pi OS Bookworm and later
        chroot_boot_dir="${CHROOT_DIR}/boot/firmware"
    else
        # Older versions or if the directory doesn't exist
        chroot_boot_dir="${CHROOT_DIR}/boot"
    fi
    
    # Bind mount the boot partition to the chroot
    mount --bind "$MOUNT_BOOT" "$chroot_boot_dir"
    info "Boot partition mounted at $chroot_boot_dir"
    
    # Install required packages
    install_packages_in_chroot "$CHROOT_DIR" "$enable_ssh"
    
    # Get keyfile name
    local keyfile_name
    keyfile_name=$(basename "$keyfile")
    
    # Create initramfs hooks
    create_initramfs_hooks "$CHROOT_DIR" "$keyfile_name" "$mapper_name" "$crypto"
    
    # Configure SSH if requested
    if [ "$enable_ssh" = "yes" ]; then
        configure_ssh_initramfs "$CHROOT_DIR" "$auth_keys_file"
    fi
    
    # Update initramfs (with boot partition mounted)
    update_initramfs "$CHROOT_DIR"
    
    # Unmount boot from chroot before configuring
    umount "$chroot_boot_dir" 2>/dev/null || true
    
    # Clean up chroot mounts before final configuration
    cleanup_chroot "$CHROOT_DIR"
    
    # Configure boot and crypttab (with boot partition mounted directly)
    configure_boot_and_crypttab "$MOUNT_BOOT" "$CHROOT_DIR" "$root_part" "$mapper_name" "$keyfile_name"
    
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

# Default values
INPUT_IMG=""
OUTPUT_IMG=""
KEYFILE=""
KEYDIR="./keys"
MAPPER_NAME="cryptroot"
CRYPTO="aes"
NO_BACKUP=0
KEEP_PASSPHRASE="no"
ENABLE_SSH="no"
AUTH_KEYS_FILE=""

# Cleanup variables
LOOP_DEV=""
WORK_DIR=""
MOUNT_ORIG=""
MOUNT_BOOT=""
MOUNT_ENCRYPTED=""
CHROOT_DIR=""
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
        --ssh)
            ENABLE_SSH="yes"
            shift
            ;;
        --authorized-keys)
            AUTH_KEYS_FILE="$2"
            shift 2
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

[ "$ENABLE_SSH" = "yes" ] && [ -z "$AUTH_KEYS_FILE" ] && errexit "--ssh requires --authorized-keys"

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
encrypt_image "$INPUT_IMG" "$OUTPUT_IMG" "$KEYFILE" "$MAPPER_NAME" "$CRYPTO" "$KEEP_PASSPHRASE" "$ENABLE_SSH" "$AUTH_KEYS_FILE"

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