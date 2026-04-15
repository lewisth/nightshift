#!/usr/bin/env bash
set -euo pipefail

BINARY="$HOME/.local/bin/nightshift"
SHARE_DIR="$HOME/.local/share/nightshift"
CONFIG_DIR="$HOME/.nightshift"

YES=0
for arg in "$@"; do
    case "$arg" in
        -y|--yes) YES=1 ;;
    esac
done

if [ "$YES" -eq 0 ]; then
    if [ ! -t 0 ]; then
        echo "Error: stdin is not a TTY. Run with -y to proceed non-interactively." >&2
        exit 1
    fi

    echo "This will remove the following nightshift components:"
    echo "  $BINARY"
    echo "  $SHARE_DIR/"
    echo "  $CONFIG_DIR/"
    echo "  nightshift cron entry"
    echo ""
    printf "Continue? [y/N] "
    read -r reply
    case "$reply" in
        y|Y) ;;
        *) echo "Aborted."; exit 0 ;;
    esac
fi

echo "Uninstalling nightshift..."

# Remove cron entry
if crontab -l 2>/dev/null | grep -q "nightshift run"; then
    crontab -l 2>/dev/null | grep -v "nightshift run" | crontab -
    echo "  Removed cron entry."
fi

# Remove binary
if [ -f "$BINARY" ]; then
    rm -f "$BINARY"
    echo "  Removed $BINARY"
fi

# Remove prompts directory
if [ -d "$SHARE_DIR" ]; then
    rm -rf "$SHARE_DIR"
    echo "  Removed $SHARE_DIR/"
fi

# Remove config and logs directory
if [ -d "$CONFIG_DIR" ]; then
    rm -rf "$CONFIG_DIR"
    echo "  Removed $CONFIG_DIR/"
fi

echo ""
echo "nightshift has been uninstalled."
