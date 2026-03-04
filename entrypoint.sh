#!/bin/bash
set -euo pipefail

# Ensure AUTHORIZED_KEY is cleared from the environment on any exit path
trap 'unset AUTHORIZED_KEY 2>/dev/null || true' EXIT

# Inject authorized key from environment
if [[ -n "${AUTHORIZED_KEY:-}" ]]; then
    echo "${AUTHORIZED_KEY}" > /home/sandbox/.ssh/authorized_keys
    chmod 600 /home/sandbox/.ssh/authorized_keys
    chown sandbox:sandbox /home/sandbox/.ssh/authorized_keys
    unset AUTHORIZED_KEY
else
    echo "WARNING: AUTHORIZED_KEY not set - no SSH keys configured, logins will fail" >&2
fi

# Ensure .ssh dir has correct permissions
chmod 700 /home/sandbox/.ssh
chown sandbox:sandbox /home/sandbox/.ssh

# Generate host keys if missing (e.g. ephemeral container without volume)
if [[ ! -f /etc/ssh/ssh_host_ed25519_key ]]; then
    ssh-keygen -A
fi

exec /usr/sbin/sshd -D -e
