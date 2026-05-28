#!/bin/bash

set -euo pipefail

TARGET="/usr/local/bin/syscheck"

if [[ $EUID -ne 0 ]]; then
    echo "Removing Syscheck as root..."
    exec sudo bash "$0" "$@"
fi

if [[ -f "$TARGET" ]]; then
    rm -f "$TARGET"
    echo "Removed: $TARGET"
else
    echo "Syscheck is not installed."
fi

if [[ -L "/usr/bin/syscheck" ]]; then
    rm -f /usr/bin/syscheck
fi

echo

read -rp "Remove config and history files too? [y/N]: " choice

case "$choice" in
    y|Y)
        rm -rf "$HOME/.system_checker"
        rm -rf "$HOME/.config/syscheck"
        echo "Removed user data."
        ;;
    *)
        echo "User data kept."
        ;;
esac

echo
echo "Syscheck successfully uninstalled."