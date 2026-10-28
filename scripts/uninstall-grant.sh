#!/bin/sh
# Removes vaken's sudoers grant.
# Run with: sudo sh scripts/uninstall-grant.sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
    echo "Run me with sudo: sudo sh scripts/uninstall-grant.sh" >&2
    exit 1
fi

rm -f /etc/sudoers.d/vaken
echo "Grant removed."
