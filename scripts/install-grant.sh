#!/bin/sh
# Installs the scoped sudoers grant for vaken's silent restore (NFR-3).
# Run once with: sudo sh scripts/install-grant.sh
set -eu

SUDOERS_D=/etc/sudoers.d
TARGET="$SUDOERS_D/vaken"
# The app passes the invoking account before elevation. Terminal callers use
# SUDO_USER. Never infer the beneficiary from the elevated process's uid.
USER_NAME=${1:-${SUDO_USER:-}}

if [ "$(id -u)" -ne 0 ]; then
    echo "Run me with sudo: sudo sh scripts/install-grant.sh" >&2
    exit 1
fi

case "$USER_NAME" in
    ''|root|*[!a-zA-Z0-9_.-]*) echo "A valid non-root account is required." >&2; exit 1 ;;
esac
USER_ID=$(/usr/bin/id -u "$USER_NAME")
[ "$USER_ID" -gt 0 ] || exit 1

# macOS commonly declares /private/etc; /etc is its system symlink.
# Match complete include paths, including quoted paths and a trailing slash.
if ! /usr/bin/grep -qsE '^[[:space:]]*[@#]includedir[[:space:]]+((/private)?/etc/sudoers[.]d/?|"(/private)?/etc/sudoers[.]d/?")([[:space:]]+#.*|[[:space:]]*)$' /etc/sudoers; then
    echo "The standard sudoers drop-in directory is not enabled. Setup was not changed." >&2
    exit 1
fi

RULE="$USER_NAME ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0"
if [ -L "$TARGET" ] || [ -L "$SUDOERS_D" ]; then
    echo "Setup path is a symbolic link. Nothing was changed." >&2; exit 1
fi
if [ -e "$TARGET" ]; then
    OWNER=$(/usr/bin/stat -f %u "$TARGET")
    [ "$OWNER" = 0 ] || { echo "Existing permission file is not root-owned." >&2; exit 1; }
    EXISTING=$(/bin/cat "$TARGET")
    if [ "$EXISTING" != "$RULE" ] && [ "$EXISTING" != "root ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0" ]; then
        echo "An unrelated permission file already exists. Nothing was changed." >&2; exit 1
    fi
fi
/usr/bin/install -d -o root -g wheel -m 0755 "$SUDOERS_D"
TMP=$(/usr/bin/mktemp "$SUDOERS_D/.vaken.XXXXXX")
trap 'rm -f "$TMP"' EXIT
printf '%s\n' "$RULE" > "$TMP"

# Validate before installing: never leave a broken sudoers behind.
/usr/sbin/visudo -cf "$TMP"

/usr/sbin/chown root:wheel "$TMP"
/bin/chmod 0440 "$TMP"
/bin/mv -f "$TMP" "$TARGET"
echo "Grant installed at $TARGET:"
cat "$TARGET"
