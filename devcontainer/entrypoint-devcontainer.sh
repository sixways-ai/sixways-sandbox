#!/bin/bash
set -euo pipefail

# The in-container sshd was retired (SixWays #560). The Dev Container is reached
# through code-server (started by /ide-entrypoint.sh) and, for the agent itself,
# the governed SSH bridge in the SixWays daemon over `docker exec` -- so this
# entrypoint no longer provisions authorized_keys, generates host keys, or runs
# sshd.

# If a command was passed (e.g. /ide-entrypoint.sh), exec it.
# Otherwise keep the container alive for docker exec attachment.
if [[ $# -gt 0 ]]; then
    exec "$@"
else
    exec sleep infinity
fi
