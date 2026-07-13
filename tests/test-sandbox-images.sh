#!/usr/bin/env bash
set -uo pipefail

# ---------------------------------------------------------------------------
# Sanity / regression suite for the sixways-sandbox container variants.
#
# Purpose: before publishing a freshness rebuild (bumped base digest + latest
# apk packages), prove the images still uphold their contract — no tool went
# missing, no runtime major jumped, privilege-escalation surface stays removed,
# the entrypoint still idles/passes-through, and the brokered-git plumbing
# (WI-SB-01: guarded credential/signing wrappers, shim path expectations, no
# credential managers, git current) stays intact. Run it AFTER building the
# images and BEFORE publishing (see the `sandbox-refresh` skill and the ghcr
# publish workflow, which runs this against its scan images as a gate).
#
# These are behavioural checks against real containers, not a substitute for
# the Trivy CVE gate (that runs separately in CI).
#
# Usage:
#   tests/test-sandbox-images.sh                 # base node python devcontainer
#   tests/test-sandbox-images.sh base node       # only the named variants
#   tests/test-sandbox-images.sh all             # + desktop (delegates to its suite)
#
# Image selection (per variant, in priority order):
#   1. IMAGE_<VARIANT> env var           e.g. IMAGE_NODE=sixways-scan:node
#   2. ${TAG_PREFIX}:<variant>           TAG_PREFIX default "sixways-sandbox"
#
# CI points TAG_PREFIX (or the per-variant vars) at the scan images it already
# built + Trivy-gated, so no image is rebuilt just to test it.
#
# Exit status: 0 iff every check passed. Any failure -> non-zero (publish gate).
# ---------------------------------------------------------------------------

TAG_PREFIX="${TAG_PREFIX:-sixways-sandbox}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

DEFAULT_VARIANTS=(base node python devcontainer)

# --- Parse args: positional variant names, or "all". ------------------------
VARIANTS=()
for arg in "$@"; do
    case "$arg" in
        all) VARIANTS=(base node python devcontainer desktop) ;;
        base|node|python|devcontainer|desktop) VARIANTS+=("$arg") ;;
        -h|--help)
            sed -n '3,40p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Unknown argument: $arg (expected: base node python devcontainer desktop all)" >&2; exit 2 ;;
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
cleanup() {
    for c in "${STARTED[@]:-}"; do
        [ -n "$c" ] && docker rm -f "$c" >/dev/null 2>&1 || true
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
    if ! docker run -d --name "$name" "$image" >/dev/null 2>&1; then
        fail "${variant}: container starts" "docker run failed for '${image}'"
        return 1
    fi
    STARTED+=("$name")
    CN="$name"; AS=""
    # The Wolfi variants idle via `sleep infinity`; give the runtime a moment.
    local i status
    for i in 1 2 3 4 5 6 7 8 9 10; do
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

    # Identity: the non-root sandbox user exists at uid 1000 with a bash login
    # shell. NOTE: the images intentionally set NO `USER` directive — they run
    # as root by default and SixWays launches them with `--user`. So we assert
    # the user EXISTS and that running AS it works, not that it is the default.
    AS=""
    assert_out "sandbox user is uid 1000"        "uid=1000" id sandbox
    assert_out "sandbox login shell is bash"     "/bin/bash" bash -c "grep '^sandbox:' /etc/passwd"

    # Privilege-escalation surface removed (core sandbox invariant). We assert
    # the REAL invariant — no suid path to root — not the mere absence of a `su`
    # binary: busybox ships an inert, non-suid `su` applet that reappears after
    # any child `apk` op (root is locked, so it cannot escalate), and gating on
    # its symlink would flap on every publish while catching nothing. `sudo` is
    # fully removed and no package re-adds it, so we still assert it is gone.
    assert_fails "sudo not on PATH"              bash -lc 'command -v sudo'
    assert_fails "sudo binary absent"            test -e /usr/bin/sudo
    assert_ok    "no suid-root binaries"         bash -lc '[ -z "$(find / -xdev -perm -4000 -type f 2>/dev/null)" ]'

    # Workspace + home laid out and owned by sandbox.
    assert_ok "/workspace owned by sandbox"      bash -lc 'find /workspace -maxdepth 0 -user sandbox | grep -q .'
    assert_ok "/home/sandbox owned by sandbox"   bash -lc 'find /home/sandbox -maxdepth 0 -user sandbox | grep -q .'

    # Actually running as the sandbox user: shell works, writes land, still no sudo.
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

# Bounded passthrough probe. A correct entrypoint execs "$@" and exits; a broken
# one (e.g. the retired sshd entrypoint that ignored "$@" and daemonized) blocks
# forever. Bound it with a portable watchdog so that becomes a clean FAIL rather
# than a hung suite — macOS/CI runners have no `timeout(1)`.
entrypoint_probe() {
    local variant="$1" image="$2"
    local token="sixways-entrypoint-ok"
    local probe="swtest-ep-${variant}-$$-${RANDOM}"
    STARTED+=("$probe")
    local out_file; out_file="$(mktemp)"
    ( sleep 25; docker rm -f "$probe" >/dev/null 2>&1 ) & local watchdog=$!
    docker run --rm --name "$probe" "$image" echo "$token" >"$out_file" 2>/dev/null || true
    kill "$watchdog" >/dev/null 2>&1 || true
    wait "$watchdog" 2>/dev/null || true
    local out; out="$(cat "$out_file" 2>/dev/null || true)"; rm -f "$out_file"
    if [[ "$out" == *"$token"* ]]; then
        pass "entrypoint execs passed command"
    else
        fail "entrypoint execs passed command" "expected '$token' within 25s (broken/blocking entrypoint?), got '$(echo "$out" | head -1)'"
    fi
}

# --- base tool surface ------------------------------------------------------
base_tools_checks() {
    AS=""
    assert_ok "git present"          bash -lc 'git --version'
    assert_ok "bash present"         bash -lc 'command -v bash'
    assert_ok "ssh client present"   bash -lc 'ssh -V'
    assert_ok "ca-certificates present" test -e /etc/ssl/certs/ca-certificates.crt
    # Tool surface AI agents expect (README variant table).
    local tool
    for tool in curl wget jq rg rsync gawk nc; do
        assert_ok "tool present: ${tool}" bash -lc "command -v ${tool}"
    done
}

# --- brokered-git plumbing (WI-SB-01, spec 5.4) ------------------------------
# Weekly freshness assertions for brokered git: the baked system config must
# keep pointing at the guarded wrappers, the wrappers must keep pointing at
# the endpoint's shim mount path, no stored-credential manager may (re)appear
# via a package bump, no insteadOf rewrite or baked token may sneak in, the
# endpoint-owned core.hooksPath must stay unset, and git must stay current
# enough for ssh signing + GIT_CONFIG_* env injection (>= 2.34 floor; the
# rebuild pulls the latest Wolfi git anyway, so the floor only catches a
# catastrophic downgrade or a variant that lost git entirely).
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
    # The shim itself is host-mounted at launch — it must NOT be baked.
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
    # Standalone contract: with no shim mounted, the credential wrapper must
    # consume the request and vend nothing, silently (exit 0, no output).
    assert_ok "credential wrapper no-ops without the shim" \
        bash -lc 'out=$(printf "protocol=https\nhost=example.invalid\n\n" | /opt/sixways/git-credential-sixways get) && [ -z "$out" ]'
}

# --- brokered-git delegation probe (fake shim mount) --------------------------
# Prove the baked config routes through the endpoint's shim mount path end to
# end, using git's own credential machinery: mount a fake shim at the exact
# path the endpoint uses and drive `git credential fill` (the same machinery
# fetch/push use to obtain credentials). Runs once, against the base layer
# every variant inherits.
git_shim_delegation_probe() {
    local variant="$1" image; image="$(image_for "$variant")"
    local fake_dir; fake_dir="$(mktemp -d)"
    local fake="${fake_dir}/sixways-git-shim"
    cat >"$fake" <<'FAKE'
#!/bin/sh
# Fake sixways-git-shim: proves wrapper -> shim delegation in the suite.
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
    if ! docker run -d --name "$name" \
            -v "${fake}:${GIT_SHIM_MOUNT_PATH}:ro" \
            "$image" >/dev/null 2>&1; then
        fail "shim delegation: container starts" "docker run with fake shim mount failed"
        rm -rf "$fake_dir"
        return
    fi
    STARTED+=("$name")
    local i status
    for i in 1 2 3 4 5 6 7 8 9 10; do
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

# --- node variant -----------------------------------------------------------
node_checks() {
    AS=""
    assert_out "node is v22"            "v22." bash -lc 'node --version'
    assert_ok  "npm works"              bash -lc 'npm --version'
    # Regression guard: npm is reinstalled from npmjs into /usr so node-gyp is
    # present. Without it, `npm i -g <native-dep pkg>` fails with
    # "Cannot find module 'node-gyp/bin/node-gyp.js'".
    assert_ok  "node-gyp present (npm reinstalled from npmjs)" \
        test -f /usr/lib/node_modules/npm/node_modules/node-gyp/bin/node-gyp.js
    # Regression guard: legacy apk builtin npmrc removed (else "Unknown builtin
    # config" warnings on every npm command).
    assert_fails "legacy builtin npmrc removed" test -e /usr/lib/node_modules/npm/npmrc
    assert_out "npm global prefix is sandbox-writable" "/home/sandbox/.npm-global" bash -lc 'npm config get prefix'
    AS="sandbox"
    assert_ok "sandbox owns npm-global prefix" bash -lc 'test -w /home/sandbox/.npm-global'
    AS=""
}

# --- python variant ---------------------------------------------------------
python_checks() {
    AS=""
    assert_out "python is 3.12"      "Python 3.12" bash -lc 'python3 --version'
    assert_ok  "pip works"           bash -lc 'python3 -m pip --version'
    assert_out "user-local bin on PATH" "/home/sandbox/.local/bin" bash -lc 'echo "$PATH"'
}

# --- devcontainer variant ---------------------------------------------------
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
    assert_ok "baked extensions dir present"    test -d /opt/extensions
    assert_ok "image version env set"           bash -lc 'test -n "$SIXWAYS_IMAGE_VERSION"'
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
    common_checks "$variant"
    case "$variant" in
        base)         base_tools_checks; git_plumbing_checks; git_shim_delegation_probe "$variant" ;;
        node)         base_tools_checks; git_plumbing_checks; node_checks ;;
        python)       base_tools_checks; git_plumbing_checks; python_checks ;;
        devcontainer) base_tools_checks; git_plumbing_checks; node_checks; devcontainer_checks ;;
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
