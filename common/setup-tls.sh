#!/bin/bash
# SixWays Sandbox -- TLS certificate setup
# Decodes base64-encoded certificates from environment variables
# into files that NGINX can read. Runs once at container startup
# before NGINX starts.

set -euo pipefail

TLS_DIR="/etc/sixways/tls"

# If env vars are missing, log a warning and exit gracefully.
# This allows the container to start without mTLS (e.g. local dev).
if [ -z "${SIXWAYS_TLS_CA_CERT:-}" ] || \
   [ -z "${SIXWAYS_TLS_SERVER_CERT:-}" ] || \
   [ -z "${SIXWAYS_TLS_SERVER_KEY:-}" ]; then
    echo "[sixways] WARNING: TLS env vars not set -- skipping mTLS setup."
    echo "[sixways] Set SIXWAYS_TLS_CA_CERT, SIXWAYS_TLS_SERVER_CERT, and SIXWAYS_TLS_SERVER_KEY to enable mTLS."
    exit 0
fi

echo "[sixways] Decoding TLS certificates to ${TLS_DIR}..."

mkdir -p "${TLS_DIR}"

# Decode certs and strip Windows \r line endings (rcgen on Windows generates \r\n)
echo "${SIXWAYS_TLS_CA_CERT}" | base64 -d | tr -d '\r' > "${TLS_DIR}/ca.crt"
echo "${SIXWAYS_TLS_SERVER_CERT}" | base64 -d | tr -d '\r' > "${TLS_DIR}/server.crt"
echo "${SIXWAYS_TLS_SERVER_KEY}" | base64 -d | tr -d '\r' > "${TLS_DIR}/server.key"

# Certs readable, key restricted
chmod 644 "${TLS_DIR}/ca.crt"
chmod 644 "${TLS_DIR}/server.crt"
chmod 600 "${TLS_DIR}/server.key"

echo "[sixways] TLS certificates written successfully."
