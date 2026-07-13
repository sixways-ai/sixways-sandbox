#!/bin/bash
set -euo pipefail

# The in-container sshd was retired (SixWays #560). "ssh into the sandbox" is
# now served by the governed SSH bridge in the SixWays daemon, and the agent is
# reached over `docker exec`, so this image ships no sshd, host keys, or
# AUTHORIZED_KEY handling.
#
# SixWays launches agents by overriding this entrypoint (its sandbox-init
# bootstrap). When the image is run standalone, exec the given command, or idle
# so an operator can attach with `docker exec`.
if [[ $# -gt 0 ]]; then
    exec "$@"
else
    exec sleep infinity
fi
