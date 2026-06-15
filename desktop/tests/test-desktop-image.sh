#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Test suite for the sixways-sandbox:desktop Docker image
# ---------------------------------------------------------------------------

IMAGE="sixways-sandbox:desktop"
CONTAINER_PREFIX="test-desktop"
SUFFIX="$(head -c 4 /dev/urandom | xxd -p)"
CONTAINER_NAME="${CONTAINER_PREFIX}-${SUFFIX}"
CONTAINER_NAME_RES="${CONTAINER_PREFIX}-res-${SUFFIX}"
CONTAINER_NAME_AGENT="${CONTAINER_PREFIX}-agent-${SUFFIX}"

PASS_COUNT=0
FAIL_COUNT=0
TOTAL_TESTS=10

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
RESET='\033[0m'

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf "${GREEN}[PASS]${RESET} %s\n" "$1"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf "${RED}[FAIL]${RESET} %s -- %s\n" "$1" "$2"
}

info() {
    printf "${YELLOW}[INFO]${RESET} %s\n" "$1"
}

header() {
    printf "\n${BOLD}=== %s ===${RESET}\n" "$1"
}

# ---------------------------------------------------------------------------
# Cleanup on exit
# ---------------------------------------------------------------------------
cleanup() {
    info "Cleaning up containers..."
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    docker rm -f "$CONTAINER_NAME_RES" 2>/dev/null || true
    docker rm -f "$CONTAINER_NAME_AGENT" 2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Helper: wait for a container to be running (up to N seconds)
# ---------------------------------------------------------------------------
wait_for_running() {
    local name="$1"
    local timeout="$2"
    local elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        local status
        status="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo "missing")"
        if [ "$status" = "running" ]; then
            return 0
        fi
        if [ "$status" = "exited" ]; then
            return 1
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    return 1
}

# ---------------------------------------------------------------------------
# Helper: retry a command up to N times with a sleep between attempts
# ---------------------------------------------------------------------------
retry() {
    local attempts="$1"
    local delay="$2"
    shift 2
    local n=0
    while [ "$n" -lt "$attempts" ]; do
        if "$@"; then
            return 0
        fi
        sleep "$delay"
        n=$((n + 1))
    done
    return 1
}

# ============================= START TESTS =================================

header "Sixways Desktop Sandbox Image Tests"
info "Image: $IMAGE"
info "Container: $CONTAINER_NAME"
echo ""

# ---------------------------------------------------------------------------
# TEST 1 -- Container starts
# ---------------------------------------------------------------------------
header "TEST 1 -- Container starts"

docker run -d \
    --name "$CONTAINER_NAME" \
    -e SIXWAYS_DESKTOP_TOKEN=testtoken \
    -p 0:8081 \
    "$IMAGE" > /dev/null 2>&1

if wait_for_running "$CONTAINER_NAME" 30; then
    pass "Container started and is running"
else
    fail "Container starts" "Container did not reach running state within 30s"
    # If the container cannot start, remaining tests will mostly fail, but we
    # continue anyway to report as much as possible.
fi

# Parse the host port assigned to 8081 (NGINX mTLS port)
HOST_PORT="$(docker port "$CONTAINER_NAME" 8081 2>/dev/null | head -n1 | sed 's/.*://')"
if [ -z "$HOST_PORT" ]; then
    info "WARNING: Could not determine host port for 8081. Some tests may fail."
    HOST_PORT="0"
fi
info "Selkies-GStreamer (via NGINX mTLS) mapped to host port $HOST_PORT"

# Give services a moment to initialize
sleep 3

# ---------------------------------------------------------------------------
# TEST 2 -- Selkies-GStreamer port responding (NGINX mTLS proxy on 8081)
# ---------------------------------------------------------------------------
header "TEST 2 -- Selkies-GStreamer port responding"

check_selkies() {
    local code
    # NGINX mTLS proxy serves over HTTPS. Without a client cert we expect
    # 400 (no client cert) or 496 (NGINX-specific no cert). Either confirms
    # the port is listening and NGINX is running.
    code="$(curl -sk -o /dev/null -w "%{http_code}" "https://localhost:${HOST_PORT}/" 2>/dev/null || echo "000")"
    if [ "$code" = "200" ] || [ "$code" = "301" ] || [ "$code" = "400" ] || [ "$code" = "496" ]; then
        return 0
    fi
    # Also try plain HTTP in case mTLS is not configured (local dev)
    code="$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${HOST_PORT}/" 2>/dev/null || echo "000")"
    if [ "$code" = "200" ] || [ "$code" = "301" ]; then
        return 0
    fi
    return 1
}

if retry 15 2 check_selkies; then
    pass "Selkies-GStreamer port is responding via NGINX"
else
    fail "Selkies-GStreamer port responding" "Did not get valid HTTP response from localhost:$HOST_PORT within retries"
fi

# ---------------------------------------------------------------------------
# TEST 3 -- Xfce4 running
# ---------------------------------------------------------------------------
header "TEST 3 -- Xfce4 running"

check_desktop() {
    docker exec "$CONTAINER_NAME" pgrep -x "xfce4-session" > /dev/null 2>&1 && return 0
    docker exec "$CONTAINER_NAME" pgrep -x "xfwm4" > /dev/null 2>&1 && return 0
    return 1
}

if retry 10 2 check_desktop; then
    pass "Desktop session is running"
else
    fail "Desktop running" "No desktop session process found (xfce4-session or xfwm4)"
fi

# ---------------------------------------------------------------------------
# TEST 4 -- Desktop tools installed
# ---------------------------------------------------------------------------
header "TEST 4 -- Desktop tools installed"

TOOLS_MISSING=""
for tool in firefox git python3 node ffmpeg zip unzip 7z; do
    if ! docker exec "$CONTAINER_NAME" bash -c "which $tool" > /dev/null 2>&1; then
        # 7z is provided by p7zip-full at /usr/bin/7z
        if [ "$tool" = "7z" ]; then
            if docker exec "$CONTAINER_NAME" bash -c "test -x /usr/bin/7z" 2>/dev/null; then
                continue
            fi
        fi
        TOOLS_MISSING="${TOOLS_MISSING} ${tool}"
    fi
done

if [ -z "$TOOLS_MISSING" ]; then
    pass "All desktop tools are installed"
else
    fail "Desktop tools installed" "Missing:${TOOLS_MISSING}"
fi

# ---------------------------------------------------------------------------
# TEST 5 -- Thunar and Mousepad installed
# ---------------------------------------------------------------------------
header "TEST 5 -- Thunar and Mousepad installed"

FM_MISSING=""
for tool in thunar mousepad; do
    if ! docker exec "$CONTAINER_NAME" bash -c "which $tool" > /dev/null 2>&1; then
        FM_MISSING="${FM_MISSING} ${tool}"
    fi
done

if [ -z "$FM_MISSING" ]; then
    pass "Thunar and Mousepad are installed"
else
    fail "Thunar and Mousepad installed" "Missing:${FM_MISSING}"
fi

# ---------------------------------------------------------------------------
# TEST 6 -- Default user
# ---------------------------------------------------------------------------
header "TEST 6 -- Default user"

WHOAMI="$(docker exec "$CONTAINER_NAME" whoami 2>/dev/null || echo "unknown")"
if [ "$WHOAMI" = "ubuntu" ]; then
    pass "Default user is 'ubuntu'"
else
    fail "Default user" "Expected 'ubuntu', got '${WHOAMI}'"
fi

# ---------------------------------------------------------------------------
# TEST 7 -- Sudo limited
# ---------------------------------------------------------------------------
header "TEST 7 -- Sudo limited"

if docker exec "$CONTAINER_NAME" sudo ls /root > /dev/null 2>&1; then
    fail "Sudo limited" "'sudo ls /root' succeeded but should have been denied"
else
    pass "Sudo correctly restricts 'ls /root'"
fi

# ---------------------------------------------------------------------------
# TEST 8 -- Agent entrypoints exist and are executable
# ---------------------------------------------------------------------------
header "TEST 8 -- Agent entrypoints exist and are executable"

ENTRYPOINTS_MISSING=""
for ep in /agents/generic-entrypoint.sh /agents/claude-entrypoint.sh /agents/openclaw-entrypoint.sh; do
    if ! docker exec "$CONTAINER_NAME" bash -c "test -x $ep" 2>/dev/null; then
        ENTRYPOINTS_MISSING="${ENTRYPOINTS_MISSING} ${ep}"
    fi
done

if [ -z "$ENTRYPOINTS_MISSING" ]; then
    pass "All agent entrypoints exist and are executable"
else
    fail "Agent entrypoints" "Missing or not executable:${ENTRYPOINTS_MISSING}"
fi

# ---------------------------------------------------------------------------
# TEST 9 -- Custom resolution
# ---------------------------------------------------------------------------
header "TEST 9 -- Custom resolution"

docker run -d \
    --name "$CONTAINER_NAME_RES" \
    -e SIXWAYS_DESKTOP_TOKEN=testtoken \
    -e DISPLAY_WIDTH=1280 \
    -e DISPLAY_HEIGHT=720 \
    "$IMAGE" > /dev/null 2>&1

if wait_for_running "$CONTAINER_NAME_RES" 30; then
    # Give the display server time to initialize
    check_resolution() {
        # Check the container logs for the resolution confirmation
        local logs
        logs="$(docker logs "$CONTAINER_NAME_RES" 2>&1)"
        if echo "$logs" | grep -q "1280x720"; then
            return 0
        fi
        # Also try xdpyinfo if available
        local res
        res="$(docker exec "$CONTAINER_NAME_RES" bash -c 'DISPLAY=:1 xdpyinfo 2>/dev/null | grep dimensions' 2>/dev/null || echo "")"
        if echo "$res" | grep -q "1280x720"; then
            return 0
        fi
        return 1
    }

    if retry 15 2 check_resolution; then
        pass "Custom resolution 1280x720 confirmed"
    else
        fail "Custom resolution" "Could not confirm 1280x720 via xdpyinfo or xrandr"
    fi
else
    fail "Custom resolution" "Resolution test container did not start"
fi

# ---------------------------------------------------------------------------
# TEST 10 -- OpenClaw agent entrypoint
# ---------------------------------------------------------------------------
header "TEST 10 -- OpenClaw agent entrypoint"

docker run -d \
    --name "$CONTAINER_NAME_AGENT" \
    -e SIXWAYS_DESKTOP_TOKEN=testtoken \
    -e SIXWAYS_AGENT_ENTRYPOINT=/agents/openclaw-entrypoint.sh \
    "$IMAGE" > /dev/null 2>&1

if wait_for_running "$CONTAINER_NAME_AGENT" 30; then
    check_openclaw_logs() {
        local logs
        logs="$(docker logs "$CONTAINER_NAME_AGENT" 2>&1)"
        if echo "$logs" | grep -qi "install"; then
            return 0
        fi
        if echo "$logs" | grep -qi "openclaw"; then
            return 0
        fi
        if echo "$logs" | grep -qi "npm"; then
            return 0
        fi
        return 1
    }

    if retry 10 3 check_openclaw_logs; then
        pass "OpenClaw agent entrypoint executed (install activity detected in logs)"
    else
        fail "OpenClaw agent entrypoint" "No install/openclaw/npm activity found in container logs"
    fi
else
    fail "OpenClaw agent entrypoint" "Agent test container did not start"
fi

# ============================= SUMMARY =====================================

echo ""
header "Test Summary"
printf "  Passed: ${GREEN}%d${RESET} / %d\n" "$PASS_COUNT" "$TOTAL_TESTS"
printf "  Failed: ${RED}%d${RESET} / %d\n" "$FAIL_COUNT" "$TOTAL_TESTS"
echo ""

if [ "$FAIL_COUNT" -gt 0 ]; then
    printf "${RED}${BOLD}SOME TESTS FAILED${RESET}\n"
    exit 1
fi

printf "${GREEN}${BOLD}ALL TESTS PASSED${RESET}\n"
exit 0
