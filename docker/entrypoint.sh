#!/bin/bash
set -e

: "${OPENCODE_SERVER_USERNAME:?Error: OPENCODE_SERVER_USERNAME is not set. Container will exit.}"
: "${OPENCODE_SERVER_PASSWORD:?Error: OPENCODE_SERVER_PASSWORD is not set. Container will exit.}"

echo "Environment validation passed."
echo "Username: $OPENCODE_SERVER_USERNAME"

if [ "$(id -u)" = '0' ]; then
    exec gosu app opencode web
fi

exec opencode web
