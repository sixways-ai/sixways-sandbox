#!/bin/bash
set -euo pipefail

# The in-container sshd was retired (SixWays #560). "ssh into the sandbox" is
# now served by the governed SSH bridge in the SixWays daemon, and the agent is
# reached over `docker exec`, so this image ships no sshd, host keys, or
# AUTHORIZED_KEY handling.
#
# SixWays launches agents by overriding this entrypoint with a root bootstrap
# that prepares mounts and then drops to uid 1000. Standalone use does not need
# that bootstrap, so make the safe identity the default without adding a USER
# directive that would break the endpoint-owned launch path.
if [[ $# -eq 0 ]]; then
    set -- sleep infinity
fi

if [[ "$(id -u)" -eq 0 ]]; then
    mkdir -p /home/sandbox/.npm /home/sandbox/.npm-global \
        /home/sandbox/.local/bin /home/sandbox/.cache/pip \
        /home/sandbox/.cargo/registry
    chown sandbox:sandbox /home/sandbox /home/sandbox/.npm \
        /home/sandbox/.npm-global /home/sandbox/.local \
        /home/sandbox/.local/bin /home/sandbox/.cache \
        /home/sandbox/.cache/pip /home/sandbox/.cargo \
        /home/sandbox/.cargo/registry
    printf -v command ' %q' "$@"
    exec su -s /bin/bash sandbox -c \
        "export HOME=/home/sandbox USER=sandbox LOGNAME=sandbox; exec${command}"
fi

exec "$@"
