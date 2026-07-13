#!/bin/bash
set -euo pipefail

# Claude Computer Use agent entrypoint for the Desktop sandbox profile.
# Installs Claude Desktop (if not already present), configures it for
# Computer Use with the specified display settings, and launches it.

echo "[sixways] Configuring Claude Computer Use agent..."

# Install Claude Desktop if not already present
if ! command -v claude-desktop &> /dev/null; then
    CLAUDE_DEB_URL="${CLAUDE_DESKTOP_URL:-https://storage.googleapis.com/anthropic-desktop/claude-desktop-latest-amd64.deb}"
    echo "[sixways] Installing Claude Desktop from ${CLAUDE_DEB_URL}..."
    curl -fsSL "${CLAUDE_DEB_URL}" -o /tmp/claude-desktop.deb
    sudo dpkg -i /tmp/claude-desktop.deb
    rm -f /tmp/claude-desktop.deb
    echo "[sixways] Claude Desktop installed."
fi

# Configure Claude Desktop for Computer Use
mkdir -p ~/.config/claude-desktop
cat > ~/.config/claude-desktop/config.json <<EOF
{
  "apiKey": "${ANTHROPIC_API_KEY:-gateway-proxied}",
  "baseUrl": "${ANTHROPIC_BASE_URL:-https://api.anthropic.com}",
  "computerUse": {
    "enabled": true,
    "displayNumber": 1,
    "displayWidth": ${DISPLAY_WIDTH:-1920},
    "displayHeight": ${DISPLAY_HEIGHT:-1080}
  }
}
EOF

echo "[sixways] Starting Claude Desktop..."
claude-desktop &

# Keep the container alive. The desktop environment (Xfce4 + Selkies-GStreamer)
# is already running from the parent desktop-entrypoint.sh.
wait
