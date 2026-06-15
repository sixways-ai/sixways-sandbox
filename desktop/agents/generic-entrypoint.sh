#!/bin/bash
set -euo pipefail

# Generic agent entrypoint for the Desktop sandbox profile.
# Used when no specific agent is configured -- provides a plain desktop
# environment that the user can interact with manually.

echo "[sixways] Desktop sandbox ready. No agent configured."
echo "[sixways] Connect via Selkies-GStreamer on port 8081 (via NGINX mTLS) to use the desktop."

# Keep the process alive. The desktop environment and streaming are
# managed by supervisord (Selkies + Xvfb + PulseAudio).
exec sleep infinity
