#!/bin/bash
set -euo pipefail

# Ensure AUTHORIZED_KEY is cleared from the environment on any exit path
trap 'unset AUTHORIZED_KEY 2>/dev/null || true' EXIT

# Inject authorized key from environment (atomic write via temp file)
if [[ -n "${AUTHORIZED_KEY:-}" ]]; then
    tmpkey=$(mktemp /home/sandbox/.ssh/authorized_keys.XXXXXX)
    echo "${AUTHORIZED_KEY}" > "$tmpkey"
    chmod 600 "$tmpkey"
    chown sandbox:sandbox "$tmpkey"
    mv "$tmpkey" /home/sandbox/.ssh/authorized_keys
    unset AUTHORIZED_KEY
else
    echo "INFO: AUTHORIZED_KEY not set -- SSH logins will require a mounted authorized_keys file" >&2
fi

# Ensure .ssh dir has correct permissions
chmod 700 /home/sandbox/.ssh
chown sandbox:sandbox /home/sandbox/.ssh

# Generate host keys if missing (e.g. ephemeral container without volume)
if [[ ! -f /etc/ssh/ssh_host_ed25519_key ]]; then
    if ! ssh-keygen -A; then
        echo "ERROR: Failed to generate SSH host keys" >&2
        exit 1
    fi
fi

# Start sshd in the background so SSH access is available alongside the Dev Container
/usr/sbin/sshd -e

# If a command was passed (e.g. /ide-entrypoint.sh), exec it.
# Otherwise keep the container alive for docker exec attachment.
if [[ $# -gt 0 ]]; then
    exec "$@"
else
    exec sleep infinity
fi
