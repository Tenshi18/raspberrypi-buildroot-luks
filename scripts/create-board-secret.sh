#!/bin/bash
#
# create-board-secret.sh - Create encrypted board overlay for GitHub Actions
#
# Usage:
#   ./scripts/create-board-secret.sh /path/to/board-secret-dir
#   ./scripts/create-board-secret.sh /path/to/board-secret-dir --upload
#

set -e

BOARD_DIR="${1:-.}"
UPLOAD="${2:-}"

if [ ! -d "$BOARD_DIR" ]; then
    echo "Error: Directory not found: $BOARD_DIR"
    echo ""
    echo "Usage: $0 /path/to/board-secret-dir [--upload]"
    echo ""
    echo "Expected structure:"
    echo "  board-secret/"
    echo "  ├── cmdline.txt              # Boot parameters"
    echo "  ├── file_permissions.txt     # File permissions table"
    echo "  └── rootfs-overlay/"
    echo "      ├── etc/"
    echo "      │   ├── NetworkManager/system-connections/*.nmconnection"
    echo "      │   └── init.d/*"
    echo "      └── root/"
    echo "          └── *.py"
    exit 1
fi

echo "=== Creating board secret archive ==="
echo "Source: $BOARD_DIR"

# Validate structure
MISSING=""
[ ! -f "$BOARD_DIR/cmdline.txt" ] && MISSING="$MISSING cmdline.txt"
[ ! -d "$BOARD_DIR/rootfs-overlay" ] && MISSING="$MISSING rootfs-overlay/"

if [ -n "$MISSING" ]; then
    echo "Warning: Missing expected files/dirs:$MISSING"
fi

# Create tar.gz and encode to base64
echo ""
echo "Creating archive..."
ARCHIVE_B64=$(tar -czf - -C "$BOARD_DIR" . | base64 -w0)

# Show size
SIZE_BYTES=${#ARCHIVE_B64}
SIZE_KB=$((SIZE_BYTES / 1024))
echo "Archive size: ${SIZE_KB} KB (base64)"

# GitHub secrets limit is 64KB
if [ $SIZE_BYTES -gt 65536 ]; then
    echo ""
    echo "Warning: Archive exceeds GitHub secret limit (64KB)"
    echo "Consider reducing files or using Google Drive for large overlays"
fi

if [ "$UPLOAD" = "--upload" ]; then
    # Upload to GitHub using gh CLI
    if ! command -v gh &> /dev/null; then
        echo "Error: 'gh' CLI not found. Install: https://cli.github.com/"
        exit 1
    fi
    
    echo ""
    echo "Uploading to GitHub Secrets..."
    echo "$ARCHIVE_B64" | gh secret set BOARD_OVERLAY_TAR_BASE64
    echo "Done! Secret BOARD_OVERLAY_TAR_BASE64 updated"
else
    # Save to file
    OUTPUT_FILE="${BOARD_DIR}.secret.b64"
    echo "$ARCHIVE_B64" > "$OUTPUT_FILE"
    echo ""
    echo "Saved to: $OUTPUT_FILE"
    echo ""
    echo "To upload to GitHub:"
    echo "  cat $OUTPUT_FILE | gh secret set BOARD_OVERLAY_TAR_BASE64"
    echo ""
    echo "Or run with --upload flag:"
    echo "  $0 $BOARD_DIR --upload"
fi

