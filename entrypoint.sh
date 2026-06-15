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
elif [[ ! -f /home/sandbox/.ssh/authorized_keys ]]; then
    echo "WARNING: AUTHORIZED_KEY not set and no existing authorized_keys - logins will fail" >&2
fi

# Ensure .ssh dir has correct permissions
chmod 700 /home/sandbox/.ssh
chown sandbox:sandbox /home/sandbox/.ssh

# Generate host keys on the writable runtime path so the rootfs can be
# mounted read-only. These paths MUST match the HostKey directives in
# sshd_config (/run/sshd/...). ssh-keygen -A is not used because it always
# targets the fixed /etc/ssh prefix and ignores the configured HostKey paths.
# /run is typically a tmpfs (and /var/run -> /run on wolfi), so /run/sshd is
# recreated here on every boot.
mkdir -p /run/sshd
if [[ ! -f /run/sshd/ssh_host_ed25519_key ]]; then
    if ! ssh-keygen -q -t ed25519 -f /run/sshd/ssh_host_ed25519_key -N ""; then
        echo "ERROR: Failed to generate SSH ed25519 host key" >&2
        exit 1
    fi
fi
if [[ ! -f /run/sshd/ssh_host_ecdsa_key ]]; then
    if ! ssh-keygen -q -t ecdsa -f /run/sshd/ssh_host_ecdsa_key -N ""; then
        echo "ERROR: Failed to generate SSH ecdsa host key" >&2
        exit 1
    fi
fi
if [[ ! -f /run/sshd/ssh_host_rsa_key ]]; then
    if ! ssh-keygen -q -t rsa -b 4096 -f /run/sshd/ssh_host_rsa_key -N ""; then
        echo "ERROR: Failed to generate SSH rsa host key" >&2
        exit 1
    fi
fi

exec /usr/sbin/sshd -D -e
