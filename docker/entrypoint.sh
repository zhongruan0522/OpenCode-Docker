#!/bin/bash
set -e

: "${OPENCODE_SERVER_USERNAME:?Error: OPENCODE_SERVER_USERNAME is not set. Container will exit.}"
: "${OPENCODE_SERVER_PASSWORD:?Error: OPENCODE_SERVER_PASSWORD is not set. Container will exit.}"

echo "Environment validation passed."
echo "Username: $OPENCODE_SERVER_USERNAME"

if [ -n "$GITHUB_TOKEN" ]; then
    echo "Configuring GitHub CLI with provided token..."
    mkdir -p /home/app/.config/gh
    echo "$GITHUB_TOKEN" | gh auth login --with-token 2>/dev/null && echo "GitHub login success." || echo "GitHub login failed."
fi

if [ -n "$GITHUB_SSH_KEY" ]; then
    echo "Configuring GitHub SSH key..."
    mkdir -p /home/app/.ssh
    echo "$GITHUB_SSH_KEY" | base64 -d > /home/app/.ssh/id_rsa
    chmod 600 /home/app/.ssh/id_rsa
    ssh-keyscan github.com >> /home/app/.ssh/known_hosts 2>/dev/null
    chown -R app:app /home/app/.ssh
    echo "GitHub SSH key configured."
fi

if [ "$(id -u)" = '0' ]; then
    LOCAL_UID=${LOCAL_UID:-10001}
    LOCAL_GID=${LOCAL_GID:-$LOCAL_UID}

    if [ "$(id -u app)" != "$LOCAL_UID" ] || [ "$(id -g app)" != "$LOCAL_GID" ]; then
        echo "Adjusting app user to uid=$LOCAL_UID, gid=$LOCAL_GID"
        groupmod -o -g "$LOCAL_GID" app
        usermod -o -u "$LOCAL_UID" -g "$LOCAL_GID" app
    fi

    chown -R app:app /home/app /workspace 2>/dev/null || true

    exec gosu app opencode serve --hostname 0.0.0.0
fi

exec opencode serve --hostname 0.0.0.0
