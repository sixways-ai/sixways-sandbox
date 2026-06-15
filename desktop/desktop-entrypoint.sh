#!/bin/bash
set -euo pipefail

# Desktop sandbox agent entrypoint -- runs inside supervisord alongside
# Selkies (WebRTC streaming), PulseAudio (audio), and the Xfce4 desktop.
#
# This script is called by supervisord AFTER the desktop is running.
# It selects and executes the appropriate agent entrypoint based on
# the SIXWAYS_AGENT_ENTRYPOINT environment variable.

echo "[sixways] Starting agent process..."

# Wait for DISPLAY to be available (Xvfb started by Selkies entrypoint)
TIMEOUT=30
ELAPSED=0
while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
    if xdpyinfo -display "${DISPLAY:-:20}" > /dev/null 2>&1; then
        break
    fi
    sleep 1
    ELAPSED=$((ELAPSED + 1))
done

if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
    echo "[sixways] WARNING: Display ${DISPLAY:-:20} not available after ${TIMEOUT}s"
fi

# Run the selected agent entrypoint
AGENT_ENTRYPOINT="${SIXWAYS_AGENT_ENTRYPOINT:-/agents/generic-entrypoint.sh}"

if [ -x "$AGENT_ENTRYPOINT" ]; then
    echo "[sixways] Running agent entrypoint: $AGENT_ENTRYPOINT"
    exec "$AGENT_ENTRYPOINT"
else
    echo "[sixways] Agent entrypoint not found or not executable: $AGENT_ENTRYPOINT"
    echo "[sixways] Running as plain desktop -- connect via port 8080."
    sleep infinity
fi
