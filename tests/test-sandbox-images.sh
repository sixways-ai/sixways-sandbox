#!/usr/bin/env bash
set -uo pipefail

# ---------------------------------------------------------------------------
# Sanity / regression suite for the sixways-sandbox container variants.
#
# Run this suite after building a refreshed image and before publishing it. The
# checks cover installed tools, runtime versions, privilege controls, entrypoint
# behavior, and the brokered Git configuration from WI-SB-01. The GHCR publish
# workflow runs the suite against its scan images as a release gate.
#
# These behavioral checks run against real containers. The Trivy CVE gate runs
# separately in CI.
#
# Usage:
#   tests/test-sandbox-images.sh                 # base node python rust go
#   tests/test-sandbox-images.sh base node       # only the named variants
#   tests/test-sandbox-images.sh all             # all first-release CLI variants
#
# Image selection (per variant, in priority order):
#   1. IMAGE_<VARIANT> env var           e.g. IMAGE_NODE=sixways-scan:node
#   2. ${TAG_PREFIX}:<variant>           TAG_PREFIX default "sixways-sandbox"
#
# CI points TAG_PREFIX or the per-variant variables at images it has already
# built and scanned, so the suite does not rebuild them.
#
# Deferred devcontainer/desktop suites remain available by explicit name only.
# They are excluded from the default and all first-release gates.
# Exit status: 0 only when every check passes; otherwise nonzero.
# ---------------------------------------------------------------------------

TAG_PREFIX="${TAG_PREFIX:-sixways-sandbox}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

DEFAULT_VARIANTS=(base node python rust go)

# --- Parse args: positional variant names, or "all". ------------------------
VARIANTS=()
for arg in "$@"; do
    case "$arg" in
        all) VARIANTS=("${DEFAULT_VARIANTS[@]}") ;;
        base|node|python|rust|go|devcontainer|desktop) VARIANTS+=("$arg") ;;
        -h|--help)
            sed -n '3,40p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Unknown argument: $arg (expected: base node python rust go devcontainer desktop all)" >&2; exit 2 ;;
    esac
done
[ "${#VARIANTS[@]}" -eq 0 ] && VARIANTS=("${DEFAULT_VARIANTS[@]}")

# --- Colours / reporting ----------------------------------------------------
if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; RESET='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BOLD=''; RESET=''
fi

PASS_COUNT=0
FAIL_COUNT=0
FAILURES=()

pass()   { PASS_COUNT=$((PASS_COUNT + 1)); printf "  ${GREEN}[PASS]${RESET} %s\n" "$1"; }
fail()   { FAIL_COUNT=$((FAIL_COUNT + 1)); FAILURES+=("$1 -- $2"); printf "  ${RED}[FAIL]${RESET} %s -- %s\n" "$1" "$2"; }
info()   { printf "  ${YELLOW}[INFO]${RESET} %s\n" "$1"; }
header() { printf "\n${BOLD}=== %s ===${RESET}\n" "$1"; }

# --- Container lifecycle ----------------------------------------------------
STARTED=()
TEMP_DIRS=()
cleanup() {
    for c in "${STARTED[@]:-}"; do
        [ -n "$c" ] && docker rm -f "$c" >/dev/null 2>&1 || true
    done
    for d in "${TEMP_DIRS[@]:-}"; do
        [ -n "$d" ] && rm -rf "$d"
    done
}
trap cleanup EXIT

# Current container under test + the user to exec as ("" => image default/root)
CN=""
AS=""

dexec() {
    if [ -n "$AS" ]; then docker exec -u "$AS" "$CN" "$@"; else docker exec "$CN" "$@"; fi
}

# assert_ok    "desc" cmd...        pass iff cmd exits 0 in the container
# assert_fails "desc" cmd...        pass iff cmd exits non-zero in the container
# assert_out   "desc" want cmd...   pass iff cmd stdout contains substring `want`
assert_ok() {
    local desc="$1"; shift
    if dexec "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc" "command failed: $*"; fi
}
assert_fails() {
    local desc="$1"; shift
    if dexec "$@" >/dev/null 2>&1; then fail "$desc" "expected non-zero exit: $*"; else pass "$desc"; fi
}
assert_out() {
    local desc="$1" want="$2"; shift 2
    local got; got="$(dexec "$@" 2>/dev/null || true)"
    if [[ "$got" == *"$want"* ]]; then pass "$desc"; else fail "$desc" "wanted '$want', got '$(echo "$got" | head -1)'"; fi
}

# Uppercase without bash-4 `^^` (CI/macOS runners ship bash 3.2).
upper() { echo "$1" | tr '[:lower:]' '[:upper:]'; }

image_for() {
    local variant="$1"
    local override_var; override_var="IMAGE_$(upper "$variant")"
    if [ -n "${!override_var:-}" ]; then echo "${!override_var}"; else echo "${TAG_PREFIX}:${variant}"; fi
}

# Mirror the endpoint's strict-tier runtime policy for CLI images. The IDE uses
# a different tier and is intentionally tested without these CLI-only mounts.
RUN_ARGS=()
run_args_for() {
    local variant="$1"
    RUN_ARGS=()
    if [ "$variant" != devcontainer ]; then
        RUN_ARGS=(
            --cap-drop=ALL
            --cap-add=CHOWN --cap-add=FOWNER --cap-add=DAC_OVERRIDE
            --cap-add=SETUID --cap-add=SETGID --cap-add=SETPCAP
            --cap-add=FSETID --cap-add=KILL
            --security-opt no-new-privileges:true
            --security-opt "seccomp=${SCRIPT_DIR}/../seccomp-sandbox.json"
            --read-only
            --tmpfs "/tmp:rw,nosuid,nodev,exec,size=256m"
            --tmpfs "/run:rw,nosuid,nodev,exec,size=128m"
            --tmpfs "/home/sandbox:rw,nosuid,nodev,exec,size=2g,uid=1000,gid=1000,mode=0755"
            --tmpfs "/workspace:rw,nosuid,nodev,exec,size=1g,uid=1000,gid=1000,mode=0755"
        )
    fi
}

# Start an idle container for `variant`; sets global CN. Returns 1 if the image
# is missing or refuses to reach the running state.
start_variant() {
    local variant="$1" image; image="$(image_for "$variant")"
    header "Variant: ${variant}  (${image})"
    if ! docker image inspect "$image" >/dev/null 2>&1; then
        fail "${variant}: image present" "no local image '${image}' (build it first, or set IMAGE_$(upper "$variant"))"
        return 1
    fi
    local name="swtest-${variant}-$$-${RANDOM}"
    run_args_for "$variant"
    if ! docker run -d --name "$name" "${RUN_ARGS[@]}" "$image" >/dev/null 2>&1; then
        fail "${variant}: container starts" "docker run failed for '${image}'"
        return 1
    fi
    STARTED+=("$name")
    CN="$name"; AS=""
    # The Wolfi variants idle via `sleep infinity`; give the runtime a moment.
    local status
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        status="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo missing)"
        [ "$status" = running ] && break
        [ "$status" = exited ] && { fail "${variant}: container idles" "container exited instead of idling"; return 1; }
        sleep 1
    done
    if [ "$status" != running ]; then
        fail "${variant}: container idles" "did not reach running state (status=$status)"
        return 1
    fi
    pass "${variant}: container starts and idles"
    return 0
}

# --- Shared contract every variant must uphold ------------------------------
common_checks() {
    local variant="$1" image; image="$(image_for "$variant")"

    # The image retains root as Config.User for the endpoint-owned bootstrap,
    # while its default entrypoint must drop PID 1 to uid 1000.
    AS=""
    assert_out "sandbox user is uid 1000"        "uid=1000" id sandbox
    assert_out "sandbox login shell is bash"     "/bin/bash" bash -c "grep '^sandbox:' /etc/passwd"
    assert_out "default PID 1 is uid 1000"       "1000" bash -lc "awk '/^Uid:/ {print \$2}' /proc/1/status"

    # Verify that the image has no path to root. BusyBox provides a non-setuid
    # `su` applet, which the endpoint needs during startup. The locked root
    # password and absence of setuid-root binaries prevent it from elevating
    # privileges. `sudo` must remain absent.
    assert_fails "sudo not on PATH"              bash -lc 'command -v sudo'
    assert_fails "sudo binary absent"            test -e /usr/bin/sudo
    assert_ok    "no suid-root binaries"         bash -lc '[ -z "$(find / -xdev -perm -4000 -type f 2>/dev/null)" ]'

    # Workspace + home laid out and owned by sandbox.
    assert_ok "/workspace owned by sandbox"      bash -lc 'find /workspace -maxdepth 0 -user sandbox | grep -q .'
    assert_ok "/home/sandbox owned by sandbox"   bash -lc 'find /home/sandbox -maxdepth 0 -user sandbox | grep -q .'

    # Verify shell access and writable directories as the sandbox user.
    AS="sandbox"
    assert_out "runs as sandbox user"            "sandbox" whoami
    assert_ok "sandbox can write /workspace"     bash -lc 'touch /workspace/.swprobe && rm -f /workspace/.swprobe'
    assert_ok "sandbox can write \$HOME"         bash -lc 'touch "$HOME/.swprobe" && rm -f "$HOME/.swprobe"'
    assert_fails "sandbox cannot escalate via sudo" bash -lc 'command -v sudo'
    # Functional escalation guard: even if a `su` exists, it must not reach root.
    # Passes unless `id -u` actually prints 0 under su (empty stdin => no hang).
    assert_fails "sandbox su cannot reach root" bash -lc 'printf "" | su root -c "id -u" 2>/dev/null | grep -qx 0'
    AS=""

    # Entrypoint passthrough: `run <image> <cmd>` must exec the command.
    entrypoint_probe "$variant" "$image"
}

# A working entrypoint executes "$@" and exits. The retired sshd entrypoint ignored
# "$@" and blocked indefinitely. A portable watchdog fails this probe after 25
# seconds because macOS and the CI runners do not provide `timeout(1)`.
entrypoint_probe() {
    local variant="$1" image="$2"
    local token="sixways-entrypoint-ok"
    local probe="swtest-ep-${variant}-$$-${RANDOM}"
    STARTED+=("$probe")
    local out_file; out_file="$(mktemp)"
    ( sleep 25; docker rm -f "$probe" >/dev/null 2>&1 ) & local watchdog=$!
    run_args_for "$variant"
    docker run --rm --name "$probe" "${RUN_ARGS[@]}" "$image" \
        bash -lc "printf '%s:%s\\n' '$token' \"\$(id -u)\"" >"$out_file" 2>/dev/null || true
    kill "$watchdog" >/dev/null 2>&1 || true
    wait "$watchdog" 2>/dev/null || true
    local out; out="$(cat "$out_file" 2>/dev/null || true)"; rm -f "$out_file"
    if [[ "$out" == *"${token}:1000"* ]]; then
        pass "entrypoint execs passed command as uid 1000"
    else
        fail "entrypoint execs passed command as uid 1000" "expected '${token}:1000' within 25s, got '$(echo "$out" | head -1)'"
    fi
}

# A standalone container must not mutate the owner of a caller-provided
# workspace bind mount. The image layer and strict-tier tmpfs already carry uid
# 1000 ownership; bind-mount ownership is caller policy, not entrypoint policy.
workspace_ownership_probe() {
    local image="$1" mount_dir before after
    mount_dir="$(mktemp -d)"
    TEMP_DIRS+=("$mount_dir")
    before="$(ls -dn "$mount_dir" | awk '{print $3 ":" $4}')"
    if ! docker run --rm -v "$mount_dir:/workspace" "$image" true >/dev/null 2>&1; then
        fail "entrypoint preserves workspace bind ownership" "bind-mount probe did not run"
        return
    fi
    after="$(ls -dn "$mount_dir" | awk '{print $3 ":" $4}')"
    if [ "$after" = "$before" ]; then
        pass "entrypoint preserves workspace bind ownership"
    else
        fail "entrypoint preserves workspace bind ownership" "owner changed from $before to $after"
    fi
}

# --- base tools -------------------------------------------------------------
base_tools_checks() {
    AS=""
    assert_ok "git present"          bash -lc 'git --version'
    assert_ok "bash present"         bash -lc 'command -v bash'
    assert_ok "ssh client present"   bash -lc 'ssh -V'
    assert_ok "ca-certificates present" test -e /etc/ssl/certs/ca-certificates.crt
    # Tools listed for the base image in README.md.
    local tool
    for tool in curl wget jq rg rsync gawk nc; do
        assert_ok "tool present: ${tool}" bash -lc "command -v ${tool}"
    done
}

# --- native build toolchain (every variant inherits it from base) -----------
# The sandbox has no sudo, a read-only rootfs on the strict tier, and runs the
# agent as uid 1000, so an agent cannot install a compiler at runtime. Missing
# tools break native npm addons and Python wheels built from source. These
# assertions prevent publication of an image without the required toolchain.
toolchain_checks() {
    AS=""
    assert_ok  "gcc present"          bash -lc 'gcc --version'
    assert_ok  "g++ present"          bash -lc 'g++ --version'
    assert_ok  "cc present"           bash -lc 'cc --version'
    assert_ok  "make present"         bash -lc 'make --version'
    assert_ok  "cmake present"        bash -lc 'cmake --version'
    assert_ok  "pkg-config present"   bash -lc 'pkg-config --version'
    assert_ok  "ld (binutils) present" bash -lc 'command -v ld'
    # Compile, link, and run code as the unprivileged sandbox user. Checking for
    # the compiler binary alone would not detect a missing linker or library.
    AS="sandbox"
    assert_out "compiles + links + runs a C program" "SW_CC_OK" bash -lc \
        'd=$(mktemp -d); printf "#include <stdio.h>\nint main(void){puts(\"SW_CC_OK\");return 0;}\n" > "$d/t.c"; cc "$d/t.c" -o "$d/t" && "$d/t"; rc=$?; rm -rf "$d"; exit $rc'
    assert_out "compiles + links + runs a C++ program" "SW_CXX_OK" bash -lc \
        'd=$(mktemp -d); printf "#include <iostream>\nint main(){std::cout<<\"SW_CXX_OK\"<<std::endl;}\n" > "$d/t.cc"; g++ "$d/t.cc" -o "$d/t" && "$d/t"; rc=$?; rm -rf "$d"; exit $rc'
    AS=""
}

# --- Brokered Git configuration (WI-SB-01, spec 5.4) ------------------------
# Check that the system configuration and wrappers use the endpoint's shim
# mount path. Reject stored-credential managers, insteadOf rewrites, embedded
# tokens, and a system core.hooksPath. Git 2.34 is the minimum version that
# supports the required SSH signing and GIT_CONFIG_* environment variables.
GIT_SHIM_MOUNT_PATH="/usr/local/bin/sixways-git-shim"
git_plumbing_checks() {
    AS=""
    assert_out "system credential.helper is the guarded wrapper" \
        "/opt/sixways/git-credential-sixways" bash -lc 'git config --system credential.helper'
    assert_out "system gpg.format is ssh" "ssh" bash -lc 'git config --system gpg.format'
    assert_out "system gpg.ssh.program is the guarded wrapper" \
        "/opt/sixways/git-ssh-sign-sixways" bash -lc 'git config --system gpg.ssh.program'
    assert_ok "credential wrapper present and executable" test -x /opt/sixways/git-credential-sixways
    assert_ok "ssh-sign wrapper present and executable"   test -x /opt/sixways/git-ssh-sign-sixways
    assert_ok "wrappers target the endpoint shim mount path" \
        bash -lc "grep -q ${GIT_SHIM_MOUNT_PATH} /opt/sixways/git-credential-sixways && grep -q ${GIT_SHIM_MOUNT_PATH} /opt/sixways/git-ssh-sign-sixways"
    # The endpoint mounts the shim at launch; the image must not include it.
    assert_fails "shim binary not baked into the image" test -e "$GIT_SHIM_MOUNT_PATH"
    # The endpoint mounts the commit-gate hooks and owns core.hooksPath via
    # GIT_CONFIG_* env; the image must never set it.
    assert_fails "image does not set core.hooksPath" bash -lc 'git config --system --get core.hooksPath'
    # No stored-credential helpers, URL rewrites, or baked auth headers.
    assert_fails "git-credential-manager absent"      bash -lc 'command -v git-credential-manager'
    assert_fails "git-credential-manager-core absent" bash -lc 'command -v git-credential-manager-core'
    assert_fails "no insteadOf rewrites in system config"  bash -lc 'git config --system --list | grep -i insteadof'
    assert_fails "no extraheader in system config"         bash -lc 'git config --system --list | grep -i extraheader'
    assert_fails "commit.gpgsign not forced by the image"  bash -lc 'git config --system --get commit.gpgsign'
    assert_ok "git version >= 2.34 (ssh signing + env config)" \
        bash -lc 'v=$(git --version | cut -d" " -f3); maj=${v%%.*}; r=${v#*.}; min=${r%%.*}; [ "$maj" -gt 2 ] || { [ "$maj" -eq 2 ] && [ "$min" -ge 34 ]; }'
    # Without a mounted shim, the credential wrapper consumes the request and
    # returns no credentials or output.
    assert_ok "credential wrapper no-ops without the shim" \
        bash -lc 'out=$(printf "protocol=https\nhost=example.invalid\n\n" | /opt/sixways/git-credential-sixways get) && [ -z "$out" ]'
}

# --- sixways-mcp-proxy (baked static musl binary) ----------------------------
# base/Dockerfile installs the proxy at the endpoint's MCP_PROXY_CONTAINER_PATH,
# pinned by common/mcp-proxy/SHA256SUMS. Check that the image carries exactly the
# pinned binary for its architecture, that it is root-owned and not writable by the
# sandbox user, and that it is a static executable that starts.
MCP_PROXY_PATH="/usr/local/bin/sixways-mcp-proxy"
mcp_proxy_checks() {
    AS=""
    assert_ok    "sixways-mcp-proxy installed and executable" test -x "$MCP_PROXY_PATH"
    assert_out   "sixways-mcp-proxy is root-owned and not group/world writable" "root 755" \
        bash -lc "stat -c '%U %a' $MCP_PROXY_PATH"
    assert_ok    "sixways-mcp-proxy provenance recorded" test -s /usr/local/share/sixways/mcp-proxy.PROVENANCE
    local arch want got
    arch="$(dexec uname -m 2>/dev/null | tr -d '\r')"
    case "$arch" in
        x86_64)         arch=amd64 ;;
        aarch64|arm64)  arch=arm64 ;;
    esac
    want="$(awk -v f="sixways-mcp-proxy-linux-${arch}" '$2 == f {print $1}' "${SCRIPT_DIR}/../common/mcp-proxy/SHA256SUMS")"
    got="$(dexec sha256sum "$MCP_PROXY_PATH" 2>/dev/null | awk '{print $1}')"
    if [ -n "$want" ] && [ "$want" = "$got" ]; then
        pass "sixways-mcp-proxy matches the pinned SHA-256 (${arch})"
    else
        fail "sixways-mcp-proxy matches the pinned SHA-256 (${arch})" "pinned '${want}', image has '${got}'"
    fi
    AS="sandbox"
    assert_out   "sandbox user can run sixways-mcp-proxy" "Usage" bash -lc "$MCP_PROXY_PATH --help 2>&1"
    assert_fails "sandbox user cannot replace sixways-mcp-proxy" bash -lc "cp /bin/true $MCP_PROXY_PATH"
    AS=""
}

# --- sixways-probe (runtime policy canary probe client) ----------------------
# base/Dockerfile installs the client at the fixed path the managed policy's reserved canary
# rule lists, pinned by common/probe/SHA256SUMS. Check the pinned digest for the image's
# architecture, that it is root-owned and not writable by the sandbox user, and that it is a
# static executable that refuses anything but its fixed argv (it must not connect anywhere
# when given no arguments).
PROBE_PATH="/usr/local/bin/sixways-probe"
probe_checks() {
    AS=""
    assert_ok    "sixways-probe installed and executable" test -x "$PROBE_PATH"
    assert_out   "sixways-probe is root-owned and not group/world writable" "root 755" \
        bash -lc "stat -c '%U %a' $PROBE_PATH"
    assert_ok    "sixways-probe provenance recorded" test -s /usr/local/share/sixways/probe.PROVENANCE
    local arch want got
    arch="$(dexec uname -m 2>/dev/null | tr -d '\r')"
    case "$arch" in
        x86_64)         arch=amd64 ;;
        aarch64|arm64)  arch=arm64 ;;
    esac
    want="$(awk -v f="sixways-probe-linux-${arch}" '$2 == f {print $1}' "${SCRIPT_DIR}/../common/probe/SHA256SUMS")"
    got="$(dexec sha256sum "$PROBE_PATH" 2>/dev/null | awk '{print $1}')"
    if [ -n "$want" ] && [ "$want" = "$got" ]; then
        pass "sixways-probe matches the pinned SHA-256 (${arch})"
    else
        fail "sixways-probe matches the pinned SHA-256 (${arch})" "pinned '${want}', image has '${got}'"
    fi
    AS="sandbox"
    assert_out   "sixways-probe refuses a call without its fixed argv" "usage:" bash -lc "$PROBE_PATH 2>&1 || true"
    assert_fails "sandbox user cannot replace sixways-probe" bash -lc "cp /bin/true $PROBE_PATH"
    AS=""
}

# --- Brokered Git delegation probe (fake shim mount) ------------------------
# Mount a fake shim at the endpoint's path, then call `git credential fill` to
# verify delegation through Git's credential helper. Run this once against the
# base layer inherited by every variant.
git_shim_delegation_probe() {
    local variant="$1" image; image="$(image_for "$variant")"
    local fake_dir; fake_dir="$(mktemp -d)"
    local fake="${fake_dir}/sixways-git-shim"
    cat >"$fake" <<'FAKE'
#!/bin/sh
# Fake sixways-git-shim for testing wrapper -> shim delegation.
if [ "${1:-}" = "credential" ]; then
    cat >/dev/null
    if [ "${2:-}" = "get" ]; then
        printf 'username=sixways-fake\npassword=sixways-fake-token\n'
    fi
    exit 0
fi
echo "fake-shim-invoked:$*"
exit 0
FAKE
    chmod 755 "$fake"
    local name="swtest-shim-${variant}-$$-${RANDOM}"
    run_args_for "$variant"
    if ! docker run -d --name "$name" \
            "${RUN_ARGS[@]}" \
            -v "${fake}:${GIT_SHIM_MOUNT_PATH}:ro" \
            "$image" >/dev/null 2>&1; then
        fail "shim delegation: container starts" "docker run with fake shim mount failed"
        rm -rf "$fake_dir"
        return
    fi
    STARTED+=("$name")
    local status
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        status="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo missing)"
        [ "$status" = running ] && break
        sleep 1
    done
    local prev_cn="$CN" prev_as="$AS"
    CN="$name"; AS=""
    assert_out "git credential fill routes through the mounted shim" "username=sixways-fake" \
        bash -lc 'printf "protocol=https\nhost=example.invalid\n\n" | git credential fill'
    assert_out "ssh-sign wrapper delegates to the mounted shim" "fake-shim-invoked:-Y sign" \
        /opt/sixways/git-ssh-sign-sixways -Y sign -n git -f /dev/null /dev/null
    CN="$prev_cn"; AS="$prev_as"
    rm -rf "$fake_dir"
}

# --- Agent runtimes (every variant must support every agent) ----------------
# SixWays does not include agents in the images. It installs the agent in the
# container at launch (`npm install -g @anthropic-ai/claude-code`,
# `pip install --user omnigent`, ... -- see `agent_install` in the endpoint),
# running as uid 1000 on a read-only root filesystem. Each image must already
# include the agent's interpreter.
#
# Image selection follows the project language, while the selected agent
# determines its runtime. A Rust project running Claude Code uses `:rust`, where
# `npm install -g` must still work. These checks run for every variant because
# Node.js and Python are inherited from `base`.
#
# The checks install local packages without contacting a registry. They cover
# prefix permissions, executable symlinks, and PATH configuration.
agent_runtime_checks() {
    AS=""
    # The endpoint's bootstrap runs as root and drops to the sandbox user with
    # `su -s /bin/sh sandbox -c '<install + exec>'`. If `su` is missing the
    # launch fails with "su: not found." BusyBox `su` is not setuid and cannot
    # elevate privileges, but it must be present for this user switch.
    assert_out "launcher can drop root -> sandbox (su -s /bin/sh)" "sandbox" \
        bash -lc 'su -s /bin/sh sandbox -c "id -un"'

    # --- Node runtime: 11 built-in agents, incl. Claude Code ---
    assert_out "node is v22"            "v22." bash -lc 'node --version'
    assert_ok  "npm works"              bash -lc 'npm --version'
    # Regression guard: npm is reinstalled from npmjs into /usr so node-gyp is
    # present. Without it, `npm i -g <native-dep pkg>` fails with
    # "Cannot find module 'node-gyp/bin/node-gyp.js'".
    assert_ok  "node-gyp present (npm reinstalled from npmjs)" \
        test -f /usr/lib/node_modules/npm/node_modules/node-gyp/bin/node-gyp.js
    # npmjs replaces the distribution package; apk must not retain ownership
    # or its stale dependency inventory after that replacement.
    assert_ok "npm installation has consistent package ownership" bash -lc \
        'command -v apk >/dev/null && test -f /usr/lib/node_modules/npm/package.json && ! apk info --who-owns /usr/lib/node_modules/npm/package.json'
    assert_ok "npm installation has no stale distribution SBOM" node -e \
        'const fs = require("node:fs"); if (fs.readdirSync("/var/lib/db/sbom").some(name => /^npm-.*\.spdx\.json$/.test(name))) process.exit(1);'
    # Regression guard: legacy apk builtin npmrc removed (else "Unknown builtin
    # config" warnings on every npm command).
    assert_fails "legacy builtin npmrc removed" test -e /usr/lib/node_modules/npm/npmrc
    assert_out "npm global prefix is sandbox-writable" "/home/sandbox/.npm-global" bash -lc 'npm config get prefix'
    # node-gyp needs a Python interpreter as well as a compiler: gyp itself is a
    # Python program, so without python3 node-gyp aborts in
    # PythonFinder.findPython before it reaches gcc, so native addons such as
    # better-sqlite3, bcrypt, and canvas fail to build. Check both dependencies.
    assert_ok  "python3 present (node-gyp requires it)" bash -lc 'python3 --version'
    assert_ok  "Node headers present for offline node-gyp" test -f /usr/include/node/node.h
    assert_out "node-gyp finds python + compiler" "gyp info ok" bash -lc \
        'd=$(mktemp -d); cd "$d"; printf "{\"targets\":[{\"target_name\":\"t\",\"sources\":[\"t.c\"]}]}\n" > binding.gyp; printf "int main(void){return 0;}\n" > t.c; node /usr/lib/node_modules/npm/node_modules/node-gyp/bin/node-gyp.js configure --nodedir=/usr 2>&1; rc=$?; cd /; rm -rf "$d"; exit $rc'

    # --- Python runtime: pip-installed agents (Omnigent, Aider, ...) ---
    assert_out "python is 3.12"      "Python 3.12" bash -lc 'python3 --version'
    assert_ok  "pip works"           bash -lc 'python3 -m pip --version'
    assert_out "user-local bin on PATH" "/home/sandbox/.local/bin" bash -lc 'echo "$PATH"'
    # Python.h comes from python-3.12-dev, not the runtime python-3.12 package.
    # Without it every source-built wheel fails with "fatal error: Python.h: No
    # such file or directory" even though gcc is present.
    assert_ok  "Python.h present (C extensions can build)" \
        bash -lc 'test -e "$(python3 -c "import sysconfig;print(sysconfig.get_paths()[\"include\"])")/Python.h"'
    assert_ok  "setuptools present"  bash -lc 'python3 -c "import setuptools"'
    assert_ok  "wheel present"       bash -lc 'python3 -c "import wheel"'

    # --- Installation paths used by the agent bootstrap ---------------------
    # Run both installers as the sandbox user and verify that their executables
    # are available on PATH.
    AS="sandbox"
    assert_ok "sandbox owns npm-global prefix" bash -lc 'test -w /home/sandbox/.npm-global'
    assert_out "npm install -g lands a working bin on PATH" "SW_NPM_AGENT_OK" bash -lc \
        'd=$(mktemp -d); mkdir -p "$d/p/bin";
         printf "{\"name\":\"sw-agent-probe\",\"version\":\"1.0.0\",\"bin\":{\"sw-agent-probe\":\"bin/cli.js\"}}\n" > "$d/p/package.json";
         printf "#!/usr/bin/env node\nconsole.log(\"SW_NPM_AGENT_OK\");\n" > "$d/p/bin/cli.js";
         chmod +x "$d/p/bin/cli.js";
         npm install -g "$d/p" >/dev/null 2>&1 && sw-agent-probe;
         rc=$?; npm uninstall -g sw-agent-probe >/dev/null 2>&1; rm -rf "$d"; exit $rc'
    assert_out "pip install --user lands a working script on PATH" "SW_PIP_AGENT_OK" bash -lc \
        'd=$(mktemp -d); mkdir -p "$d/p";
         printf "from setuptools import setup\nsetup(name=\"sw-pip-probe\", version=\"1.0.0\", scripts=[\"sw-pip-probe\"])\n" > "$d/p/setup.py";
         printf "#!/bin/sh\necho SW_PIP_AGENT_OK\n" > "$d/p/sw-pip-probe";
         chmod +x "$d/p/sw-pip-probe";
         pip install --user --no-index --no-build-isolation "$d/p" >/dev/null 2>&1 && sw-pip-probe;
         rc=$?; pip uninstall -y sw-pip-probe >/dev/null 2>&1; rm -rf "$d"; exit $rc'
    # Compile a C extension as the sandbox user to test the compiler and
    # Python.h together.
    assert_out "builds + imports a C extension" "SW_PYEXT_OK" bash -lc \
        'd=$(mktemp -d); cd "$d";
         printf "#include <Python.h>\nstatic PyMethodDef M[]={{NULL,NULL,0,NULL}};\nstatic struct PyModuleDef m={PyModuleDef_HEAD_INIT,\"swext\",NULL,-1,M};\nPyMODINIT_FUNC PyInit_swext(void){return PyModule_Create(&m);}\n" > swext.c;
         printf "from setuptools import setup, Extension\nsetup(name=\"swext\", ext_modules=[Extension(\"swext\",[\"swext.c\"])])\n" > setup.py;
         python3 setup.py build_ext --inplace >/dev/null 2>&1 && python3 -c "import swext; print(\"SW_PYEXT_OK\")";
         rc=$?; cd /; rm -rf "$d"; exit $rc'
    AS=""
}

# --- rust variant -----------------------------------------------------------
rust_checks() {
    AS=""
    assert_ok  "rustc present"       bash -lc 'rustc --version'
    assert_ok  "cargo present"       bash -lc 'cargo --version'
    assert_out "CARGO_HOME is sandbox-writable" "/home/sandbox/.cargo" bash -lc 'echo "$CARGO_HOME"'
    # rustc invokes the system `cc`, so compile, link, and run a program as the
    # sandbox user.
    AS="sandbox"
    assert_ok  "sandbox owns CARGO_HOME" bash -lc 'test -w /home/sandbox/.cargo'
    assert_out "cargo builds + runs a binary" "SW_RUST_OK" bash -lc \
        'd=$(mktemp -d); cd "$d"; cargo init --name swp -q >/dev/null 2>&1; printf "fn main(){println!(\"SW_RUST_OK\");}\n" > src/main.rs; cargo run -q --offline 2>/dev/null; rc=$?; cd /; rm -rf "$d"; exit $rc'
    AS=""
}

# --- go variant -------------------------------------------------------------
go_checks() {
    AS=""
    assert_ok  "go present"          bash -lc 'go version'
    assert_out "GOPATH is sandbox-writable"  "/home/sandbox/go" bash -lc 'echo "$GOPATH"'
    assert_out "GOCACHE is sandbox-writable" "/home/sandbox/.cache/go-build" bash -lc 'echo "$GOCACHE"'
    AS="sandbox"
    # The strict tier mounts a fresh tmpfs over HOME. Test cache creation as
    # the agent user instead of expecting image-layer directories to survive.
    assert_ok  "sandbox can create GOPATH + GOCACHE" bash -lc 'mkdir -p "$GOPATH" "$GOCACHE" && test -w "$GOPATH" && test -w "$GOCACHE"'
    assert_out "go builds + runs a binary" "SW_GO_OK" bash -lc \
        'd=$(mktemp -d); cd "$d"; go mod init swp >/dev/null 2>&1; printf "package main\nimport \"fmt\"\nfunc main(){fmt.Println(\"SW_GO_OK\")}\n" > main.go; go run . 2>/dev/null; rc=$?; cd /; rm -rf "$d"; exit $rc'
    # cgo is the reason the go variant depends on base's C toolchain.
    assert_out "cgo builds (uses base's C compiler)" "SW_CGO_OK" bash -lc \
        'd=$(mktemp -d); cd "$d"; go mod init swc >/dev/null 2>&1; printf "package main\n\n// int seven(){return 7;}\nimport \"C\"\nimport \"fmt\"\nfunc main(){if C.seven()==7 {fmt.Println(\"SW_CGO_OK\")}}\n" > main.go; CGO_ENABLED=1 go run . 2>/dev/null; rc=$?; cd /; rm -rf "$d"; exit $rc'
    AS=""
}

# --- devcontainer variant ---------------------------------------------------
devcontainer_mtls_probe() {
    local image name tls_tmp host_port status rejected accepted ready
    image="$(image_for devcontainer)"
    name="swtest-ide-mtls-$$-${RANDOM}"
    tls_tmp="$(mktemp -d)"
    TEMP_DIRS+=("$tls_tmp")

    if ! openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
            -subj '/CN=SixWays IDE Test CA' \
            -keyout "$tls_tmp/ca.key" -out "$tls_tmp/ca.crt" >/dev/null 2>&1 \
        || ! openssl req -newkey rsa:2048 -nodes -subj '/CN=localhost' \
            -keyout "$tls_tmp/server.key" -out "$tls_tmp/server.csr" >/dev/null 2>&1 \
        || ! openssl x509 -req -days 1 -in "$tls_tmp/server.csr" \
            -CA "$tls_tmp/ca.crt" -CAkey "$tls_tmp/ca.key" -CAcreateserial \
            -out "$tls_tmp/server.crt" >/dev/null 2>&1 \
        || ! openssl req -newkey rsa:2048 -nodes -subj '/CN=SixWays IDE Test Client' \
            -keyout "$tls_tmp/client.key" -out "$tls_tmp/client.csr" >/dev/null 2>&1 \
        || ! openssl x509 -req -days 1 -in "$tls_tmp/client.csr" \
            -CA "$tls_tmp/ca.crt" -CAkey "$tls_tmp/ca.key" -CAcreateserial \
            -out "$tls_tmp/client.crt" >/dev/null 2>&1; then
        fail "IDE mTLS: certificates generated" "openssl could not create the ephemeral test PKI"
        return
    fi

    # SYS_PTRACE is test-only: code-server marks itself non-dumpable, and this
    # lets the container operator inspect PID 1's actual environment below.
    if ! docker run -d --name "$name" --cap-add=SYS_PTRACE -p 127.0.0.1::8080 \
            -e PASSWORD=sixways-password-must-not-leak \
            -e "SIXWAYS_TLS_CA_CERT=$(base64 < "$tls_tmp/ca.crt" | tr -d '\n')" \
            -e "SIXWAYS_TLS_SERVER_CERT=$(base64 < "$tls_tmp/server.crt" | tr -d '\n')" \
            -e "SIXWAYS_TLS_SERVER_KEY=$(base64 < "$tls_tmp/server.key" | tr -d '\n')" \
            "$image" /ide-entrypoint.sh >/dev/null 2>&1; then
        fail "IDE mTLS: container starts" "docker run failed for the positive mTLS path"
        return
    fi
    STARTED+=("$name")

    host_port="$(docker port "$name" 8080/tcp 2>/dev/null | head -n1 | sed 's/.*://')"
    if [ -z "$host_port" ]; then
        fail "IDE mTLS: published port" "Docker did not allocate a host port for 8080"
        return
    fi

    ready=false
    rejected="000"
    accepted="000"
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
        status="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo missing)"
        [ "$status" = exited ] && break
        rejected="$(curl -sk -o /dev/null -w '%{http_code}' \
            "https://127.0.0.1:${host_port}/" 2>/dev/null || true)"
        accepted="$(curl -sk --cert "$tls_tmp/client.crt" --key "$tls_tmp/client.key" \
            -o /dev/null -w '%{http_code}' "https://127.0.0.1:${host_port}/" \
            2>/dev/null || true)"
        if { [ "$rejected" = 400 ] || [ "$rejected" = 496 ]; } \
            && [[ "$accepted" =~ ^[23][0-9][0-9]$ ]]; then
            ready=true
            break
        fi
        sleep 2
    done

    if [ "$ready" = true ]; then
        pass "IDE mTLS rejects anonymous clients and accepts the ephemeral client certificate"
    else
        fail "IDE mTLS proxy" "container status=${status:-unknown}, anonymous=${rejected}, authenticated=${accepted}"
    fi

    if docker exec "$name" bash -lc \
        'test "$(stat -c "%u:%g %a" /etc/sixways/tls/ca.crt)" = "1000:1000 644" &&
         test "$(stat -c "%u:%g %a" /etc/sixways/tls/server.crt)" = "1000:1000 644" &&
         test "$(stat -c "%u:%g %a" /etc/sixways/tls/server.key)" = "1000:1000 600"'; then
        pass "IDE mTLS certificates have sandbox ownership and safe modes"
    else
        fail "IDE mTLS certificate ownership" "decoded files do not have the expected uid 1000 modes"
    fi

    if docker exec "$name" bash -lc \
        'test "$(stat -c %u /proc/1)" = 1000 &&
         for pid in $(pgrep nginx); do test "$(stat -c %u "/proc/$pid")" = 1000 || exit 1; done'; then
        pass "IDE mTLS code-server and NGINX run as uid 1000"
    else
        fail "IDE mTLS process identity" "PID 1 or an NGINX process is not uid 1000"
    fi

    # Inspect as the container operator (uid 0). Capture first so a read failure
    # cannot turn the negative grep into a false pass.
    if docker exec -u 0 "$name" bash -lc \
        'environment="$(xargs -0 -n1 < /proc/1/environ)" &&
         ! grep -q "^PASSWORD=" <<< "$environment"'; then
        pass "IDE mTLS removes PASSWORD before code-server inherits the environment"
    else
        fail "IDE mTLS PASSWORD hygiene" "PASSWORD is present in code-server's environment"
    fi
}

devcontainer_checks() {
    AS=""
    # Inherits node.
    assert_out "node present (inherits node)" "v22." bash -lc 'node --version'
    assert_ok "nginx present"        bash -lc 'command -v nginx'
    assert_ok "procps (ps) present"  bash -lc 'command -v ps'
    assert_ok "devcontainer entrypoint present" test -x /entrypoint-devcontainer.sh
    assert_ok "ide entrypoint present"          test -x /ide-entrypoint.sh
    assert_ok "nginx mTLS config present"       test -e /etc/sixways/nginx-mtls.conf
    assert_ok "setup-tls helper present"        test -x /opt/sixways/setup-tls.sh
    assert_ok "code-server is baked and executable" test -x /opt/code-server/bin/code-server
    assert_out "code-server version is pinned" "4.136.2" /opt/code-server/bin/code-server --version
    assert_fails "IDE refuses missing TLS by default" /ide-entrypoint.sh
    assert_fails "insecure IDE override still requires a password" \
        bash -lc 'SIXWAYS_ALLOW_INSECURE_IDE=1 /ide-entrypoint.sh'
    assert_fails "TLS setup rejects invalid base64" bash -lc \
        'SIXWAYS_TLS_CA_CERT=x SIXWAYS_TLS_SERVER_CERT=x SIXWAYS_TLS_SERVER_KEY=x /opt/sixways/setup-tls.sh'
    assert_ok "baked extensions dir present"    test -d /opt/extensions
    assert_ok "image version env set"           bash -lc 'test -n "$SIXWAYS_IMAGE_VERSION"'
    devcontainer_mtls_probe
}

# --- desktop variant: delegate to its own dedicated suite -------------------
run_desktop() {
    local image; image="$(image_for desktop)"
    header "Variant: desktop  (${image})"
    if [ ! -x "${SCRIPT_DIR}/../desktop/tests/test-desktop-image.sh" ]; then
        fail "desktop: suite present" "desktop/tests/test-desktop-image.sh not found"
        return
    fi
    if ! docker image inspect "$image" >/dev/null 2>&1; then
        fail "desktop: image present" "no local image '${image}'"
        return
    fi
    info "delegating to desktop/tests/test-desktop-image.sh"
    if IMAGE="$image" bash "${SCRIPT_DIR}/../desktop/tests/test-desktop-image.sh"; then
        pass "desktop suite passed"
    else
        fail "desktop suite" "desktop/tests/test-desktop-image.sh reported failures"
    fi
}

# ============================ RUN ==========================================
header "SixWays Sandbox image sanity/regression suite"
info "Variants: ${VARIANTS[*]}"
info "Tag prefix: ${TAG_PREFIX}"

# Fail fast if docker is unusable.
if ! docker info >/dev/null 2>&1; then
    printf "${RED}${BOLD}Docker is not available/running.${RESET}\n" >&2
    exit 2
fi

for variant in "${VARIANTS[@]}"; do
    if [ "$variant" = desktop ]; then
        run_desktop
        continue
    fi
    if ! start_variant "$variant"; then
        continue
    fi
    # Run the base tool, toolchain, and runtime checks for every variant. Then
    # run checks for packages added by the selected variant.
    common_checks "$variant"
    base_tools_checks
    toolchain_checks
    agent_runtime_checks
    git_plumbing_checks
    mcp_proxy_checks
    probe_checks
    case "$variant" in
        base)         git_shim_delegation_probe "$variant"; workspace_ownership_probe "$(image_for "$variant")" ;;
        node)         : ;;
        python)       : ;;
        rust)         rust_checks ;;
        go)           go_checks ;;
        devcontainer) devcontainer_checks ;;
    esac
done

# ============================ SUMMARY ======================================
header "Summary"
TOTAL=$((PASS_COUNT + FAIL_COUNT))
printf "  Passed: ${GREEN}%d${RESET} / %d\n" "$PASS_COUNT" "$TOTAL"
printf "  Failed: ${RED}%d${RESET} / %d\n" "$FAIL_COUNT" "$TOTAL"
if [ "$FAIL_COUNT" -gt 0 ]; then
    echo ""
    printf "${RED}${BOLD}FAILURES:${RESET}\n"
    for f in "${FAILURES[@]}"; do printf "  - %s\n" "$f"; done
    echo ""
    printf "${RED}${BOLD}SOME TESTS FAILED — do not publish.${RESET}\n"
    exit 1
fi
echo ""
printf "${GREEN}${BOLD}ALL TESTS PASSED${RESET}\n"
exit 0
