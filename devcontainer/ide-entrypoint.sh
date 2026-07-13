#!/bin/bash
set -euo pipefail

# IDE entrypoint: bootstraps code-server inside the container, then runs it.
# code-server and extensions persist in ~/.code-server across restarts.
#
# NOTE: the in-container sshd was retired (SixWays #560); the parent entrypoint
# (entrypoint-devcontainer.sh) execs this script via "$@" and no longer runs
# sshd. code-server is the access path.

# --- mTLS proxy setup ---
# Decode TLS certs from env vars (gracefully skips if not set)
if [[ -x /opt/sixways/setup-tls.sh ]]; then
    /opt/sixways/setup-tls.sh
fi

# Detect whether mTLS certs were written -- controls port binding below
MTLS_ENABLED=false
if [[ -f /etc/sixways/tls/server.crt ]] && [[ -f /etc/sixways/tls/server.key ]]; then
    MTLS_ENABLED=true
fi

# --- code-server bootstrap ---
CODE_SERVER_DIR="/home/sandbox/.code-server"
CODE_SERVER_BIN="${CODE_SERVER_DIR}/bin/code-server"
CODE_SERVER_DATA="${CODE_SERVER_DIR}/data"

# Version stamp: re-install code-server + extensions when image version changes.
# This ensures updates propagate through persistent volumes.
IMAGE_VERSION_FILE="${CODE_SERVER_DIR}/.image-version"
CURRENT_IMAGE_VERSION="${SIXWAYS_IMAGE_VERSION:-unknown}"
CACHED_IMAGE_VERSION=$(cat "${IMAGE_VERSION_FILE}" 2>/dev/null || echo "")
FORCE_REINSTALL=false
if [[ "${CURRENT_IMAGE_VERSION}" != "${CACHED_IMAGE_VERSION}" && "${CURRENT_IMAGE_VERSION}" != "unknown" ]]; then
    FORCE_REINSTALL=true
fi

# Install code-server if not present or image version changed
if [[ ! -x "${CODE_SERVER_BIN}" ]] || [[ "${FORCE_REINSTALL}" == "true" ]]; then
    echo "Installing code-server (${FORCE_REINSTALL:+image updated}${FORCE_REINSTALL:-first launch})..."
    mkdir -p "${CODE_SERVER_DIR}"
    curl -fsSL https://code-server.dev/install.sh | \
        sh -s -- --version=4.100.3 --prefix="${CODE_SERVER_DIR}" --method=standalone
    echo "code-server installed."
fi

# --- Extension installation ---

# Clean up stale extension installs and fix ownership.
# The entrypoint runs as root but code-server runs as sandbox -- fix any
# root-owned files from prior installs, and remove broken temp dirs.
if [[ -d "${CODE_SERVER_DATA}/extensions" ]]; then
    find "${CODE_SERVER_DATA}/extensions" -maxdepth 1 -name "*.vsctmp" -exec rm -rf {} + 2>/dev/null || true
    chown -R sandbox:sandbox "${CODE_SERVER_DATA}/extensions" 2>/dev/null || true
fi

# 1. Install SixWays Endpoint extension if not present or outdated.
#    First check the baked .vsix version, then try Open VSX for newer.
INSTALLED_VERSION=$("${CODE_SERVER_BIN}" --extensions-dir "${CODE_SERVER_DATA}/extensions" \
    --list-extensions --show-versions 2>/dev/null | grep "sixways.endpoint@" | cut -d@ -f2 || echo "")
BAKED_VERSION=""
for vsix in /opt/extensions/endpoint-*.vsix /opt/extensions/sixways.endpoint-*.vsix; do
    [[ -e "$vsix" ]] || continue
    # Extract version from filename: endpoint-0.1.0.vsix → 0.1.0
    BAKED_VERSION=$(echo "$vsix" | sed 's/.*-\([0-9][0-9.]*\)\.vsix/\1/')
    break
done

NEEDS_INSTALL=false
if [[ -z "${INSTALLED_VERSION}" ]]; then
    NEEDS_INSTALL=true
    echo "SixWays Endpoint extension not installed."
elif [[ -n "${BAKED_VERSION}" && "${INSTALLED_VERSION}" != "${BAKED_VERSION}" ]]; then
    NEEDS_INSTALL=true
    echo "SixWays Endpoint extension outdated (${INSTALLED_VERSION} → ${BAKED_VERSION})."
elif [[ "${FORCE_REINSTALL}" == "true" ]]; then
    NEEDS_INSTALL=true
    echo "Image version changed, reinstalling extensions."
fi

if [[ "${NEEDS_INSTALL}" == "true" ]]; then
    # Remove existing extension dir completely to avoid rename conflicts
    rm -rf "${CODE_SERVER_DATA}/extensions/sixways.endpoint-"* 2>/dev/null || true
    mkdir -p "${CODE_SERVER_DATA}/extensions"
    # Try baked .vsix first (instant, no network)
    BAKED_INSTALLED=false
    for vsix in /opt/extensions/*.vsix; do
        [[ -e "$vsix" ]] || continue
        echo "Installing baked extension: ${vsix}"
        "${CODE_SERVER_BIN}" --extensions-dir "${CODE_SERVER_DATA}/extensions" \
            --install-extension "${vsix}" --force 2>/dev/null && BAKED_INSTALLED=true || true
    done
    # Fall back to Open VSX if no baked .vsix or baked install failed
    if [[ "${BAKED_INSTALLED}" != "true" ]]; then
        echo "Installing SixWays Endpoint from Open VSX..."
        "${CODE_SERVER_BIN}" --extensions-dir "${CODE_SERVER_DATA}/extensions" \
            --install-extension "sixways.endpoint" 2>/dev/null || true
    fi
    # Fix ownership and clean up any temp dirs left by the install
    find "${CODE_SERVER_DATA}/extensions" -maxdepth 1 -name "*.vsctmp" -exec rm -rf {} + 2>/dev/null || true
    chown -R sandbox:sandbox "${CODE_SERVER_DATA}/extensions" 2>/dev/null || true
else
    echo "SixWays Endpoint extension up to date (${INSTALLED_VERSION})."
fi

# 2. Install Claude Code if not present (default IDE agent)
if ! "${CODE_SERVER_BIN}" --extensions-dir "${CODE_SERVER_DATA}/extensions" \
    --list-extensions 2>/dev/null | grep -q "anthropic.claude-code"; then
    echo "Installing Claude Code extension..."
    "${CODE_SERVER_BIN}" --extensions-dir "${CODE_SERVER_DATA}/extensions" \
        --install-extension "anthropic.claude-code" 2>/dev/null || true
fi

# 3. User/policy extensions from env var (set by daemon or workbench)
for ext in ${IDE_EXTENSIONS:-}; do
    if [[ -n "$ext" ]]; then
        echo "Ensuring extension: ${ext}"
        "${CODE_SERVER_BIN}" --extensions-dir "${CODE_SERVER_DATA}/extensions" \
            --install-extension "${ext}" 2>/dev/null || true
    fi
done

# Update version stamp after successful setup
if [[ "${CURRENT_IMAGE_VERSION}" != "unknown" ]]; then
    echo "${CURRENT_IMAGE_VERSION}" > "${IMAGE_VERSION_FILE}"
fi

# --- Sync host VS Code settings (if mounted) ---
if [[ -d "/tmp/vscode-settings" ]]; then
    mkdir -p "${CODE_SERVER_DATA}/User"
    for f in settings.json keybindings.json; do
        if [[ -f "/tmp/vscode-settings/$f" ]]; then
            cp "/tmp/vscode-settings/$f" "${CODE_SERVER_DATA}/User/$f"
            echo "Synced VS Code $f"
        fi
    done
    if [[ -d "/tmp/vscode-settings/snippets" ]]; then
        cp -r "/tmp/vscode-settings/snippets" "${CODE_SERVER_DATA}/User/snippets"
        echo "Synced VS Code snippets"
    fi
fi

# Inject color theme into settings.json if provided and not already set
if [[ -n "${IDE_SYNC_THEME_NAME:-}" ]] && [[ -f "${CODE_SERVER_DATA}/User/settings.json" ]]; then
    if ! grep -q '"workbench.colorTheme"' "${CODE_SERVER_DATA}/User/settings.json"; then
        tmpfile=$(mktemp)
        jq --arg theme "${IDE_SYNC_THEME_NAME}" '. + {"workbench.colorTheme": $theme}' \
            "${CODE_SERVER_DATA}/User/settings.json" > "${tmpfile}"
        mv "${tmpfile}" "${CODE_SERVER_DATA}/User/settings.json"
        echo "Injected color theme: ${IDE_SYNC_THEME_NAME}"
    fi
elif [[ -n "${IDE_SYNC_THEME_NAME:-}" ]] && [[ ! -f "${CODE_SERVER_DATA}/User/settings.json" ]]; then
    mkdir -p "${CODE_SERVER_DATA}/User"
    jq -n --arg theme "${IDE_SYNC_THEME_NAME}" '{"workbench.colorTheme": $theme}' \
        > "${CODE_SERVER_DATA}/User/settings.json"
    echo "Created settings with color theme: ${IDE_SYNC_THEME_NAME}"
fi

# --- Clean up synced extensions when sync is off ---
# When extension sync is disabled, remove all extensions except the core ones
# (sixways.endpoint and anthropic.claude-code)
if [[ -z "${IDE_SYNC_EXTENSIONS:-}" ]] && [[ -d "${CODE_SERVER_DATA}/extensions" ]]; then
    SYNC_MARKER="${CODE_SERVER_DATA}/extensions/.synced-extensions"
    if [[ -f "${SYNC_MARKER}" ]]; then
        echo "Removing previously synced extensions..."
        while IFS= read -r ext_dir; do
            if [[ -d "${CODE_SERVER_DATA}/extensions/${ext_dir}" ]]; then
                rm -rf "${CODE_SERVER_DATA}/extensions/${ext_dir}"
                echo "Removed: ${ext_dir}"
            fi
        done < "${SYNC_MARKER}"
        rm -f "${SYNC_MARKER}"
    fi
    # Also remove any non-core extensions (catch extensions synced before marker existed)
    for ext_dir in "${CODE_SERVER_DATA}/extensions/"*/; do
        [[ -d "$ext_dir" ]] || continue
        dir_name=$(basename "$ext_dir")
        case "$dir_name" in
            sixways.endpoint-*|anthropic.claude-code-*) continue ;;
            .*) continue ;;  # skip dotfiles
        esac
        rm -rf "$ext_dir"
        echo "Removed non-core extension: ${dir_name}"
    done
    # Clean the extensions.json registry to match (keep only core extensions)
    if [[ -f "${CODE_SERVER_DATA}/extensions/extensions.json" ]] && command -v jq >/dev/null 2>&1; then
        jq '[.[] | select(.identifier.id | test("^(sixways\\.endpoint|anthropic\\.claude-code)"; "i"))]' \
            "${CODE_SERVER_DATA}/extensions/extensions.json" > "${CODE_SERVER_DATA}/extensions/extensions.json.tmp" \
            && mv "${CODE_SERVER_DATA}/extensions/extensions.json.tmp" "${CODE_SERVER_DATA}/extensions/extensions.json" \
            && echo "Cleaned extensions.json registry" || true
    fi
fi

# Fix ownership after extension installs (entrypoint runs as root)
chown -R sandbox:sandbox "${CODE_SERVER_DIR}" 2>/dev/null || true

# Determine code-server bind address based on mTLS mode.
# With mTLS: NGINX listens on 0.0.0.0:8080 (TLS), code-server on 127.0.0.1:8085 (internal).
# Without mTLS: code-server listens on 0.0.0.0:8080 directly (backward compatible).
if [[ "${MTLS_ENABLED}" == "true" ]]; then
    CS_BIND="127.0.0.1:8085"
    echo "Starting code-server on ${CS_BIND} (NGINX mTLS proxy on 0.0.0.0:8080)..."
else
    CS_BIND="0.0.0.0:8080"
    echo "Starting code-server on ${CS_BIND}..."
fi

# Use password auth if PASSWORD env var is set, otherwise no auth
# (workbench proxies with its own token auth; endpoint sets PASSWORD)
AUTH_MODE="none"
if [[ -n "${PASSWORD:-}" ]]; then
    AUTH_MODE="password"
    # Write password to code-server config so the login page shows a
    # helpful message instead of "$PASSWORD"
    mkdir -p "${CODE_SERVER_DATA}"
    cat > "${CODE_SERVER_DATA}/config.yaml" <<CSEOF
bind-addr: ${CS_BIND}
auth: password
password: ${PASSWORD}
cert: false
CSEOF
    # Clear from environment so it doesn't leak to child processes
    unset PASSWORD
fi

# Build code-server args
CS_ARGS="--disable-telemetry --disable-update-check --user-data-dir ${CODE_SERVER_DATA} --extensions-dir ${CODE_SERVER_DATA}/extensions"
if [[ "${AUTH_MODE}" == "password" ]]; then
    CS_ARGS="--config ${CODE_SERVER_DATA}/config.yaml ${CS_ARGS}"
else
    CS_ARGS="--bind-addr ${CS_BIND} --auth none ${CS_ARGS}"
fi

# Start NGINX mTLS proxy in the background if certs are available
if [[ "${MTLS_ENABLED}" == "true" ]]; then
    echo "[sixways] Starting NGINX mTLS proxy..."
    nginx -g 'daemon off;' -c /etc/sixways/nginx-mtls.conf &
    NGINX_PID=$!
    echo "[sixways] NGINX started (PID ${NGINX_PID})."
fi

# Check if background extension installs are needed
NEED_BG_INSTALL=false
if [[ -n "${IDE_SYNC_THEMES:-}" ]] || [[ -n "${IDE_SYNC_EXTENSIONS:-}" ]]; then
    NEED_BG_INSTALL=true
fi

if [[ "${NEED_BG_INSTALL}" == "true" ]]; then
    # Start code-server in background so we can install extensions concurrently
    ${CODE_SERVER_BIN} ${CS_ARGS} /workspace &
    CS_PID=$!

    # Background: install theme extensions
    if [[ -n "${IDE_SYNC_THEMES:-}" ]]; then
        (
            sleep 3
            IFS=',' read -ra THEMES <<< "${IDE_SYNC_THEMES}"
            for ext in "${THEMES[@]}"; do
                [[ -z "$ext" ]] && continue
                echo "[bg] Installing theme: ${ext}"
                "${CODE_SERVER_BIN}" --extensions-dir "${CODE_SERVER_DATA}/extensions" \
                    --install-extension "${ext}" 2>/dev/null || true
            done
            chown -R sandbox:sandbox "${CODE_SERVER_DATA}/extensions" 2>/dev/null || true
            echo "[bg] Theme sync complete."
        ) &
    fi

    # Background: install user extensions
    if [[ -n "${IDE_SYNC_EXTENSIONS:-}" ]]; then
        (
            sleep 5
            SYNC_MARKER="${CODE_SERVER_DATA}/extensions/.synced-extensions"
            > "${SYNC_MARKER}"  # clear marker
            IFS=',' read -ra EXTS <<< "${IDE_SYNC_EXTENSIONS}"
            for ext in "${EXTS[@]}"; do
                [[ -z "$ext" ]] && continue
                # Skip extensions already installed
                if "${CODE_SERVER_BIN}" --extensions-dir "${CODE_SERVER_DATA}/extensions" \
                    --list-extensions 2>/dev/null | grep -qi "^${ext}$"; then
                    continue
                fi
                echo "[bg] Installing extension: ${ext}"
                if "${CODE_SERVER_BIN}" --extensions-dir "${CODE_SERVER_DATA}/extensions" \
                    --install-extension "${ext}" 2>/dev/null; then
                    # Record the installed extension dir for cleanup
                    ls -d "${CODE_SERVER_DATA}/extensions/${ext}-"* 2>/dev/null | \
                        xargs -I{} basename {} >> "${SYNC_MARKER}" || true
                fi
            done
            chown -R sandbox:sandbox "${CODE_SERVER_DATA}/extensions" 2>/dev/null || true
            echo "[bg] Extension sync complete ($(wc -l < "${SYNC_MARKER}") extensions)."

            # Re-verify core extensions weren't clobbered by the sync
            for core_ext in sixways.endpoint anthropic.claude-code; do
                if ! ls -d "${CODE_SERVER_DATA}/extensions/${core_ext}-"* >/dev/null 2>&1; then
                    echo "[bg] Core extension ${core_ext} missing after sync, reinstalling..."
                    "${CODE_SERVER_BIN}" --extensions-dir "${CODE_SERVER_DATA}/extensions" \
                        --install-extension "${core_ext}" --force 2>/dev/null || true
                fi
            done
            # Also try baked .vsix for sixways endpoint
            if ! ls -d "${CODE_SERVER_DATA}/extensions/sixways.endpoint-"* >/dev/null 2>&1; then
                for vsix in /opt/extensions/*.vsix; do
                    [[ -e "$vsix" ]] || continue
                    echo "[bg] Reinstalling baked extension: ${vsix}"
                    "${CODE_SERVER_BIN}" --extensions-dir "${CODE_SERVER_DATA}/extensions" \
                        --install-extension "${vsix}" --force 2>/dev/null || true
                done
            fi
            chown -R sandbox:sandbox "${CODE_SERVER_DATA}/extensions" 2>/dev/null || true
        ) &
    fi

    # Wait for code-server (keeps container alive)
    wait $CS_PID
else
    # No background installs needed -- exec directly
    exec ${CODE_SERVER_BIN} ${CS_ARGS} /workspace
fi
