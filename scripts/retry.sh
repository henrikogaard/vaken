#!/bin/bash
# Run a command up to three times. Apple's ticket server can drop the connection briefly.
# Fails with the last attempt's status.
set -uo pipefail
attempt=1
while true; do
    status=0
    "$@" || status=$?
    [[ $status -eq 0 ]] && exit 0
    [[ $attempt -ge 3 ]] && exit "$status"
    echo "Command failed with status $status (attempt $attempt of 3); retrying: $*" >&2
    sleep $((attempt * ${VAKEN_RETRY_DELAY:-5}))
    attempt=$((attempt + 1))
done
