#!/bin/bash
# SixWays Sandbox TLS certificate setup
# Decodes base64-encoded certificates from environment variables
# into files that NGINX can read. Runs once at container startup
# before NGINX starts.

set -euo pipefail

TLS_DIR="/etc/sixways/tls"

# Missing credentials are fatal. IDE-only local development may opt into the
# password-protected fallback explicitly; desktop never has an insecure mode.
if [ -z "${SIXWAYS_TLS_CA_CERT:-}" ] || \
   [ -z "${SIXWAYS_TLS_SERVER_CERT:-}" ] || \
   [ -z "${SIXWAYS_TLS_SERVER_KEY:-}" ]; then
    if [ "${SIXWAYS_ALLOW_INSECURE_IDE:-}" = "1" ]; then
        echo "[sixways] WARNING: explicit insecure IDE mode enabled; mTLS is disabled." >&2
        exit 0
    fi
    echo "[sixways] ERROR: mTLS credentials are required." >&2
    echo "[sixways] Set SIXWAYS_TLS_CA_CERT, SIXWAYS_TLS_SERVER_CERT, and SIXWAYS_TLS_SERVER_KEY." >&2
    exit 1
fi

echo "[sixways] Decoding TLS certificates to ${TLS_DIR}..."

umask 077
mkdir -p "${TLS_DIR}"

CA_TMP=$(mktemp "${TLS_DIR}/.ca.XXXXXX")
CERT_TMP=$(mktemp "${TLS_DIR}/.cert.XXXXXX")
KEY_TMP=$(mktemp "${TLS_DIR}/.key.XXXXXX")
cleanup() {
    rm -f "${CA_TMP}" "${CERT_TMP}" "${KEY_TMP}"
}
trap cleanup EXIT

# Decode certs and strip Windows \r line endings (rcgen on Windows generates \r\n)
printf '%s' "${SIXWAYS_TLS_CA_CERT}" | base64 -d | tr -d '\r' > "${CA_TMP}"
printf '%s' "${SIXWAYS_TLS_SERVER_CERT}" | base64 -d | tr -d '\r' > "${CERT_TMP}"
printf '%s' "${SIXWAYS_TLS_SERVER_KEY}" | base64 -d | tr -d '\r' > "${KEY_TMP}"

mv "${CA_TMP}" "${TLS_DIR}/ca.crt"
mv "${CERT_TMP}" "${TLS_DIR}/server.crt"
mv "${KEY_TMP}" "${TLS_DIR}/server.key"
trap - EXIT

# Certs readable, key restricted
chmod 644 "${TLS_DIR}/ca.crt"
chmod 644 "${TLS_DIR}/server.crt"
chmod 600 "${TLS_DIR}/server.key"

echo "[sixways] TLS certificates written successfully."
