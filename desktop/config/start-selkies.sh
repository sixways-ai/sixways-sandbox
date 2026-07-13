#!/bin/bash

TURN_PASS="${SELKIES_TURN_PASSWORD:-turnpassword}"

# Patch the Selkies web client to:
# 1. Force relay mode (iceTransportPolicy: relay) -- avoids mDNS failures in Docker
# 2. Use TCP transport for TURN -- Docker Desktop UDP forwarding is unreliable
# The default iceTransportPolicy is "all" and TURN URLs use UDP.
if [ -f /opt/gst-web/webrtc.js ]; then
    sed -i 's/"iceTransportPolicy": "all"/"iceTransportPolicy": "relay"/' /opt/gst-web/webrtc.js 2>/dev/null || true
fi

# Use --turn_host/--turn_port so the browser receives the TURN config.
# (--rtc_config_json only affects the server-side GStreamer, not the browser)
exec selkies-gstreamer \
    --addr=127.0.0.1 \
    --port=8082 \
    --enable_basic_auth="${SELKIES_ENABLE_BASIC_AUTH:-true}" \
    --basic_auth_user="${SELKIES_BASIC_AUTH_USER:-ubuntu}" \
    --basic_auth_password="${SELKIES_BASIC_AUTH_PASSWORD:-password}" \
    --encoder="${SELKIES_ENCODER:-x264enc}" \
    --enable_resize="${SELKIES_ENABLE_RESIZE:-false}" \
    --turn_host="${SELKIES_TURN_HOST:-localhost}" \
    --turn_port=3478 \
    --turn_username=selkies \
    --turn_password="${TURN_PASS}"
