#!/bin/bash
#
# batch-encrypt-images.sh - Create multiple encrypted images with unique keys
#
# Usage: ./batch-encrypt-images.sh base.img count [prefix] [output_dir]
#
# Example: ./batch-encrypt-images.sh buildroot.img 10 device_ ./encrypted/
#   Creates: device_001.img, device_002.img, ... device_010.img
#   With unique keyfiles: device_001.lek, device_002.lek, ...
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENCRYPT_SCRIPT="${SCRIPT_DIR}/pre-burn-encrypt.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

function errexit() {
    echo -e "${RED}Error: $1${NC}" >&2
    exit 1
}

function info() {
    echo -e "${GREEN}$1${NC}"
}

function printhelp() {
    cat << 'EOF'
batch-encrypt-images.sh - Create multiple encrypted images with unique keys

USAGE:
    sudo ./batch-encrypt-images.sh [OPTIONS] base.img count

OPTIONS:
    --prefix PREFIX     Image filename prefix (default: device_)
    --output-dir DIR    Output directory (default: ./encrypted)
    --key-dir DIR       Key storage directory (default: ./keys)
    --manifest FILE     Output manifest file (default: manifest.csv)
    --parallel N        Number of parallel jobs (default: 1)
    --crypto TYPE       Encryption type: aes or xchacha
    --dry-run           Show what would be done without doing it
    --help              Show this help

EXAMPLES:
    # Create 10 encrypted images
    sudo ./batch-encrypt-images.sh buildroot.img 10

    # Custom prefix and output directory
    sudo ./batch-encrypt-images.sh --prefix factory_ --output-dir /mnt/images buildroot.img 50

    # Parallel processing (4 jobs)
    sudo ./batch-encrypt-images.sh --parallel 4 buildroot.img 100

OUTPUT:
    Creates encrypted images and a manifest CSV file containing:
    - Image filename
    - Keyfile UUID
    - Keyfile path
    - Creation timestamp

EOF
    exit 0
}

function create_manifest_header() {
    local manifest="$1"
    echo "image_file,keyfile_uuid,keyfile_path,created_at" > "$manifest"
}

function add_manifest_entry() {
    local manifest="$1"
    local image="$2"
    local keyfile="$3"
    local keyuuid
    
    keyuuid=$(basename "$keyfile" .lek)
    echo "$(basename "$image"),$keyuuid,$keyfile,$(date -Iseconds)" >> "$manifest"
}

function encrypt_single() {
    local base_img="$1"
    local output_img="$2"
    local key_dir="$3"
    local crypto="$4"
    local manifest="$5"
    local num="$6"
    local total="$7"
    
    echo -e "${CYAN}[$num/$total]${NC} Creating: $(basename "$output_img")"
    
    # Run encryption
    "$ENCRYPT_SCRIPT" \
        --keydir "$key_dir" \
        --crypto "$crypto" \
        "$base_img" "$output_img"
    
    # Find the generated keyfile (most recent .lek in key_dir)
    local keyfile
    keyfile=$(ls -t "$key_dir"/*.lek 2>/dev/null | head -1)
    
    if [ -n "$keyfile" ] && [ -n "$manifest" ]; then
        add_manifest_entry "$manifest" "$output_img" "$keyfile"
    fi
}

#
# Main
#

[ "$EUID" -ne 0 ] && errexit "This script must be run as root"

# Default values
PREFIX="device_"
OUTPUT_DIR="./encrypted"
KEY_DIR="./keys"
MANIFEST="manifest.csv"
PARALLEL=1
CRYPTO="aes"
DRY_RUN=0
BASE_IMG=""
COUNT=""

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)
            PREFIX="$2"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --key-dir)
            KEY_DIR="$2"
            shift 2
            ;;
        --manifest)
            MANIFEST="$2"
            shift 2
            ;;
        --parallel)
            PARALLEL="$2"
            shift 2
            ;;
        --crypto)
            CRYPTO="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --help|-h)
            printhelp
            ;;
        -*)
            errexit "Unknown option: $1"
            ;;
        *)
            if [ -z "$BASE_IMG" ]; then
                BASE_IMG="$1"
            elif [ -z "$COUNT" ]; then
                COUNT="$1"
            else
                errexit "Too many arguments"
            fi
            shift
            ;;
    esac
done

# Validate
[ -z "$BASE_IMG" ] && printhelp
[ -z "$COUNT" ] && printhelp
[ ! -f "$BASE_IMG" ] && errexit "Base image not found: $BASE_IMG"
[ ! -f "$ENCRYPT_SCRIPT" ] && errexit "Encryption script not found: $ENCRYPT_SCRIPT"
[[ ! "$COUNT" =~ ^[0-9]+$ ]] && errexit "Count must be a number"
[ "$COUNT" -lt 1 ] && errexit "Count must be at least 1"

# Create directories
mkdir -p "$OUTPUT_DIR" "$KEY_DIR"
MANIFEST_PATH="${OUTPUT_DIR}/${MANIFEST}"

info "=============================================="
info "Batch Encryption Configuration"
info "=============================================="
echo "Base image:     $BASE_IMG"
echo "Count:          $COUNT"
echo "Prefix:         $PREFIX"
echo "Output dir:     $OUTPUT_DIR"
echo "Key dir:        $KEY_DIR"
echo "Manifest:       $MANIFEST_PATH"
echo "Crypto:         $CRYPTO"
echo "Parallel jobs:  $PARALLEL"
echo ""

if [ $DRY_RUN -eq 1 ]; then
    info "DRY RUN - No actual encryption will be performed"
    echo ""
    for i in $(seq 1 "$COUNT"); do
        printf "Would create: %s%03d.img with unique keyfile\n" "$PREFIX" "$i"
    done
    exit 0
fi

# Create manifest header
create_manifest_header "$MANIFEST_PATH"

# Determine number width for zero-padding
WIDTH=${#COUNT}
[ $WIDTH -lt 3 ] && WIDTH=3

info "Starting batch encryption..."
echo ""

START_TIME=$(date +%s)

if [ "$PARALLEL" -gt 1 ]; then
    # Parallel processing
    export -f encrypt_single add_manifest_entry
    export ENCRYPT_SCRIPT KEY_DIR CRYPTO MANIFEST_PATH COUNT
    
    seq 1 "$COUNT" | xargs -P "$PARALLEL" -I {} bash -c '
        num={}
        padded=$(printf "%0'"$WIDTH"'d" "$num")
        output="${OUTPUT_DIR}/${PREFIX}${padded}.img"
        encrypt_single "$BASE_IMG" "$output" "$KEY_DIR" "$CRYPTO" "$MANIFEST_PATH" "$num" "$COUNT"
    '
else
    # Sequential processing
    for i in $(seq 1 "$COUNT"); do
        padded=$(printf "%0${WIDTH}d" "$i")
        output_img="${OUTPUT_DIR}/${PREFIX}${padded}.img"
        
        encrypt_single "$BASE_IMG" "$output_img" "$KEY_DIR" "$CRYPTO" "$MANIFEST_PATH" "$i" "$COUNT"
    done
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo ""
info "=============================================="
info "Batch Encryption Complete!"
info "=============================================="
echo ""
echo "Created:        $COUNT encrypted images"
echo "Output dir:     $OUTPUT_DIR"
echo "Key dir:        $KEY_DIR"
echo "Manifest:       $MANIFEST_PATH"
echo "Duration:       ${DURATION}s ($(echo "scale=1; $DURATION / $COUNT" | bc)s per image)"
echo ""
info "Next steps:"
echo "  1. Secure backup of keyfiles in $KEY_DIR"
echo "  2. Create USB key disks with individual .lek files"
echo "  3. Burn images to SD cards"
echo ""

