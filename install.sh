#!/bin/bash

set -euo pipefail

VERSION="2.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SOURCE="$SCRIPT_DIR/syscheck.sh"

TARGET_DIR="/usr/local/bin"
TARGET_NAME="syscheck"
TARGET="$TARGET_DIR/$TARGET_NAME"

if [[ ! -f "$SOURCE" ]]; then
    echo "Error: source file not found:"
    echo "$SOURCE"
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "Installing Syscheck v$VERSION as root..."
    exec sudo bash "$0" "$@"
fi

mkdir -p "$TARGET_DIR"

install -Dm755 "$SOURCE" "$TARGET"

ln -sf "$TARGET" /usr/bin/syscheck

echo
echo "========================================"
echo " Syscheck v$VERSION installed"
echo "========================================"
echo
echo "Command:"
echo "  syscheck"
echo
echo "Help:"
echo "  syscheck --help"
echo
