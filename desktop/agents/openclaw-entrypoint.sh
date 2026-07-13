#!/bin/bash
set -euo pipefail

# OpenClaw Desktop agent entrypoint for the Desktop sandbox profile.
# Installs OpenClaw, sets up a split read-only/writable directory structure,
# generates hardened security defaults, and starts the gateway.

echo "[sixways] Configuring OpenClaw Desktop agent..."

OPENCLAW_DIR="$HOME/.openclaw"
OPENCLAW_DATA="$HOME/.openclaw-data"
GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-$(python3 -c 'import secrets; print(secrets.token_hex(32))')}"

# Install or upgrade OpenClaw globally via npm
echo "[sixways] Installing OpenClaw..."
npm install -g openclaw@latest

# Create writable data directories (state that persists across restarts)
mkdir -p "$OPENCLAW_DATA/agents/main/agent"
mkdir -p "$OPENCLAW_DATA/extensions"
mkdir -p "$OPENCLAW_DATA/workspace/memory"
mkdir -p "$OPENCLAW_DATA/workspace/skills"
mkdir -p "$OPENCLAW_DATA/hooks"
mkdir -p "$OPENCLAW_DATA/identity"
mkdir -p "$OPENCLAW_DATA/devices"
mkdir -p "$OPENCLAW_DATA/canvas"
mkdir -p "$OPENCLAW_DATA/cron"
mkdir -p "$OPENCLAW_DATA/credentials"

# Create the read-only config root
mkdir -p "$OPENCLAW_DIR"

# Symlink from config root to writable data directories so OpenClaw
# finds everything in its expected location while config stays read-only.
for dir in agents extensions workspace hooks identity devices canvas cron credentials; do
    ln -sfn "$OPENCLAW_DATA/$dir" "$OPENCLAW_DIR/$dir"
done

# Generate hardened security config
# - exec allowlist restricts which commands the agent can run
# - gateway binds to loopback only with token auth
# - channel writes to config are disabled by default
cat > "$OPENCLAW_DIR/openclaw.json" <<OCEOF
{
  "agents": {
    "defaults": {
      "model": {
        "primary": "${OPENCLAW_MODEL:-anthropic/claude-sonnet-4-6}"
      }
    }
  },
  "models": {
    "mode": "merge",
    "providers": {
      "anthropic": {
        "baseUrl": "${ANTHROPIC_BASE_URL:-https://api.anthropic.com}",
        "apiKey": "${ANTHROPIC_API_KEY:-gateway-proxied}",
        "api": "anthropic-messages"
      },
      "openai": {
        "baseUrl": "${OPENAI_BASE_URL:-https://api.openai.com/v1}",
        "apiKey": "${OPENAI_API_KEY:-gateway-proxied}",
        "api": "openai-completions"
      }
    }
  },
  "tools": {
    "exec": {
      "security": "allowlist",
      "allowlist": ["git *", "npm *", "ls *", "cat *", "echo *", "node *", "python3 *"],
      "ask": "on-miss"
    }
  },
  "channels": {
    "defaults": { "configWrites": false },
    "telegram": {
      "enabled": ${TELEGRAM_ENABLED:-false},
      "dmPolicy": "allowlist",
      "groupPolicy": "disabled"
    },
    "discord": { "enabled": ${DISCORD_ENABLED:-false} },
    "slack": { "enabled": ${SLACK_ENABLED:-false}, "mode": "socket" }
  },
  "gateway": {
    "port": 18789,
    "bind": "loopback",
    "auth": { "mode": "token", "token": "${GATEWAY_TOKEN}" },
    "controlUi": true
  }
}
OCEOF

# Write .env with channel tokens (kept separate from config)
cat > "$OPENCLAW_DIR/.env" <<ENVEOF
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN:-}
DISCORD_BOT_TOKEN=${DISCORD_BOT_TOKEN:-}
SLACK_BOT_TOKEN=${SLACK_BOT_TOKEN:-}
SLACK_APP_TOKEN=${SLACK_APP_TOKEN:-}
OPENCLAW_GATEWAY_TOKEN=${GATEWAY_TOKEN}
ENVEOF
chmod 600 "$OPENCLAW_DIR/.env"

# Lock config to prevent the agent from weakening its own security settings
chmod 444 "$OPENCLAW_DIR/openclaw.json"

echo "[sixways] Starting OpenClaw Gateway on port 18789..."
openclaw gateway --port 18789 --bind loopback &

# Keep the container alive. The desktop environment (Xfce4 + Selkies-GStreamer)
# is already running from the parent desktop-entrypoint.sh.
wait
