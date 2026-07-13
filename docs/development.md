# Development Guide: sixways-sandbox

Local build, test, and troubleshooting guide for SixWays Sandbox container images.

## Prerequisites

- **Docker Desktop** (macOS or Windows)
- **Node.js 18+** and **npm** (for building the VS Code extension)

## Image Build Chain

The images form a dependency chain. Always build from the base up.

```
base (Wolfi + git + bash + ssh client)
  |
  +-- node (+ Node.js 22 LTS + npm)
  |     |
  |     +-- devcontainer (+ nginx + code-server bootstrap + extensions)
  |
  +-- python (+ Python 3.12 + pip)

desktop (separate chain: Ubuntu + Selkies-GStreamer + Xfce4)
```

**Key rule**: If you rebuild a parent image, you must rebuild all children.
Rebuilding only the leaf image inherits stale parent layers.

## Building Images Locally

### 1. Build the VS Code extension first

The devcontainer image bakes the SixWays Endpoint extension (`.vsix`) for offline
install. Build it before building the devcontainer image.

```bash
cd /path/to/endpoint-vscode
npm install          # if node_modules is missing
npm run build        # compile TypeScript -> dist/extension.js
npm run package      # creates endpoint-0.1.0.vsix
```

Copy the built `.vsix` into the sandbox repo:

```bash
cp endpoint-0.1.0.vsix /path/to/sixways-sandbox/devcontainer/extensions/
```

### 2. Build the Docker image chain

Run from the `sixways-sandbox` repo root. The `--platform` flag is critical on
Apple Silicon (see [ARM64 / Apple Silicon](#arm64--apple-silicon) below).

```bash
cd /path/to/sixways-sandbox

# 1. Base image (tag as GHCR name so child FROM resolves locally)
docker build --platform linux/arm64 \
  -t sixways-sandbox:base \
  -t ghcr.io/sixways-ai/sixways-sandbox:latest \
  -f base/Dockerfile .

# 2. Node variant
docker build --platform linux/arm64 \
  -t sixways-sandbox:node \
  -t ghcr.io/sixways-ai/sixways-sandbox:node \
  -f node/Dockerfile node/

# 3. Devcontainer (IDE sandbox) -- build context must be repo root
docker build --platform linux/arm64 \
  -t sixways-sandbox:devcontainer \
  -f devcontainer/Dockerfile .

# 4. Python variant (optional)
docker build --platform linux/arm64 \
  -t sixways-sandbox:python \
  -f python/Dockerfile python/

# 5. Desktop variant (optional, separate chain)
docker build --platform linux/arm64 \
  -t sixways-sandbox:desktop \
  -f desktop/Dockerfile desktop/
```

On Windows/Linux x86_64 hosts, replace `--platform linux/arm64` with
`--platform linux/amd64` (or omit it entirely).

### 3. Verify architecture

```bash
docker inspect sixways-sandbox:devcontainer --format '{{.Architecture}}'
# Expected: arm64  (on Apple Silicon)
# Expected: amd64  (on x86_64)
```

## Clean Slate Rebuild

When things go wrong (stale volumes, architecture mismatch, broken state),
do a full clean rebuild:

```bash
# 1. Stop and remove any running sandbox containers
docker ps -a --filter "name=sixways" -q | xargs -r docker rm -f

# 2. Remove persistent volumes (contain stale binaries from old arch)
docker volume rm sixways-sandbox-home sixways-cache-npm sixways-cache-pip sixways-cache-cargo 2>/dev/null

# 3. Rebuild the full chain with --no-cache and --pull
docker build --platform linux/arm64 --no-cache --pull \
  -t sixways-sandbox:base \
  -t ghcr.io/sixways-ai/sixways-sandbox:latest \
  -f base/Dockerfile .

docker build --platform linux/arm64 --no-cache \
  -t sixways-sandbox:node \
  -t ghcr.io/sixways-ai/sixways-sandbox:node \
  -f node/Dockerfile node/

docker build --platform linux/arm64 --no-cache \
  -t sixways-sandbox:devcontainer \
  -f devcontainer/Dockerfile .

# 4. Verify
docker inspect sixways-sandbox:devcontainer --format '{{.Architecture}}'
```

**When to do a clean slate**:
- After switching between amd64 and arm64
- After pulling new GHCR images that may be a different architecture
- When code-server exits with code 127 (wrong-arch binary in volume)
- When the IDE sandbox shows unexpected behavior after an image rebuild

## ARM64 / Apple Silicon

Docker Desktop on Apple Silicon runs an ARM64 Linux VM. Getting native ARM64
containers requires attention to several details:

### Always specify `--platform`

Without `--platform linux/arm64`, Docker may pull cached amd64 layers or resolve
a multi-arch manifest to the wrong platform.

```bash
# Correct
docker build --platform linux/arm64 -t sixways-sandbox:base -f base/Dockerfile .

# Wrong (may silently use amd64 cache)
docker build -t sixways-sandbox:base -f base/Dockerfile .
```

### Do not pin base image digests for local builds

The base Dockerfile (`base/Dockerfile`) uses a tag without a SHA digest:

```dockerfile
FROM cgr.dev/chainguard/wolfi-base:latest
```

CI may pin a digest for reproducibility. **Do not copy a CI digest into your
local Dockerfile** -- SHA digests resolve to a single platform manifest. If the
pinned digest is amd64, your arm64 build silently gets an emulated image.

### Persistent volumes retain old-arch binaries

Docker named volumes (`sixways-sandbox-home`, `sixways-cache-*`) persist across
container recreations. If you rebuild from amd64 to arm64, the volume still
contains amd64 binaries (e.g., code-server). The new arm64 container tries to
run them and fails with `exit 127` or segfaults.

**Fix**: Remove volumes after an architecture change:

```bash
docker volume rm sixways-sandbox-home sixways-cache-npm sixways-cache-pip sixways-cache-cargo
```

Bind mounts (like `~/.claude/`) don't have this problem -- they reflect the host
filesystem directly.

### Detecting emulation

If you see this warning during build or run, you're running under emulation:

```
WARNING: The requested image's platform (linux/amd64) does not match
the detected host platform (linux/arm64/v8)
```

Or if `ps aux` in the container shows `/run/rosetta/rosetta` wrapping processes,
the container is running x86_64 binaries through Rosetta translation.

## macOS-Specific: Claude Code Authentication

On macOS, Claude Code stores OAuth credentials in the Keychain -- not in files.
On Windows/Linux, credentials are stored as `~/.claude/.credentials.json`.

The SixWays Endpoint daemon (`sixwaysd`) handles this automatically:

1. Extracts the full credential JSON from the macOS Keychain
2. Writes it to `~/.claude/.credentials.json` (with `0600` permissions)
3. The `~/.claude/` bind mount carries the file into the container
4. The Claude Code extension inside code-server reads it normally

If authentication fails inside the IDE sandbox on macOS:

1. Verify you're logged into Claude Code on the host: `claude` in terminal
2. Check the Keychain entry exists: `security find-generic-password -s "Claude Code-credentials" -w | head -c 50`
3. Check the credentials file was written: `ls -la ~/.claude/.credentials.json`
4. Inside the container, verify ownership: `docker exec <container> ls -la /home/sandbox/.claude/.credentials.json`

The file should be owned by `sandbox:sandbox` (the bootstrap script chowns it).

## UID Mapping and Permissions

macOS Docker Desktop maps host uid 501 (your user) to uid 0 (root) inside the
container. Files in bind mounts appear as `root:root` inside the container, but
the sandbox user (uid 1000) needs to read them.

The container bootstrap script fixes ownership:

```sh
chown -R sandbox:sandbox /home/sandbox/.claude 2>/dev/null || true
chown sandbox:sandbox /home/sandbox/.claude.json 2>/dev/null || true
```

If you add new bind mounts containing files the sandbox user needs to read,
add a corresponding `chown` to the bootstrap script in
`sixways-sandbox-lib/src/docker/mod.rs`.

## Testing a Local Build

### Quick smoke test (docker exec)

The in-container sshd was retired (SixWays #560); the base image idles so you
attach with `docker exec`.

```bash
cid=$(docker run -d sixways-sandbox:base)
docker exec -it "$cid" bash
which sudo  # should fail (removed at build time)
docker rm -f "$cid"
```

### IDE sandbox test (via sixwaysd)

1. Build the endpoint daemon with your auth fix:
   ```bash
   cd /path/to/sixways-endpoint
   cargo build
   ```

2. Launch an IDE sandbox from the SixWays UI (Agents tab > Launch)

3. Verify inside the container:
   - `docker inspect <container> --format '{{.Architecture}}'` -- should be `arm64`
   - No `/run/rosetta/rosetta` wrapper in `ps aux`
   - Claude Code extension shows "Auth method: Claude AI" (not "Not authenticated")
   - Only core extensions installed (sixways.endpoint + anthropic.claude-code)

## Debugging

```bash
# Container logs
docker logs <container-id>

# Shell into running container
docker exec -it <container-id> /bin/bash

# Check what's in the persistent volume
docker run --rm -v sixways-sandbox-home:/data alpine ls -la /data/

# Check extension state
docker exec <container> ls -la /home/sandbox/.code-server/data/extensions/

# Check code-server version and architecture
docker exec <container> file /home/sandbox/.code-server/lib/code-server-*/lib/node
```

## Common Issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| `exit 127` from code-server | Wrong-arch binary in persistent volume | `docker volume rm sixways-sandbox-home` |
| "Not authenticated" on macOS | Missing `~/.claude/.credentials.json` | Rebuild sixwaysd (`cargo build`) with auth fix; verify Keychain entry exists |
| "Not authenticated" (any OS) | Bind-mounted `.claude` owned by root | Check bootstrap chown runs; verify container logs |
| Emulation warning on Apple Silicon | amd64 image on arm64 host | Rebuild with `--platform linux/arm64 --no-cache --pull` |
| Extension not loading | Stale extension in volume | `docker volume rm sixways-sandbox-home` or launch with `--clean` |
| code-server downloads on every launch | Volume was removed or clean mode | Expected on first launch; cached in `~/.code-server` afterward |
| eBPF sidecar exits immediately | Docker Desktop doesn't expose BPF | Expected on macOS/Windows; eBPF only works on native Linux |
| Build uses wrong base image | Stale Docker cache | Use `--no-cache --pull` on the base build |

## File Reference

| File | Purpose |
|------|---------|
| `base/Dockerfile` | Wolfi base + git + bash + ssh client + common tools |
| `node/Dockerfile` | Node.js 22 LTS + npm (extends base) |
| `python/Dockerfile` | Python 3.12 + pip (extends base) |
| `devcontainer/Dockerfile` | IDE support: nginx, code-server bootstrap, baked extensions (extends node) |
| `desktop/Dockerfile` | Desktop sandbox: Ubuntu + Selkies-GStreamer + Xfce4 (separate chain) |
| `entrypoint.sh` | Base entrypoint: passthrough (exec args or idle for docker exec) |
| `devcontainer/entrypoint-devcontainer.sh` | Devcontainer entrypoint: exec args (code-server) or sleep |
| `devcontainer/ide-entrypoint.sh` | IDE bootstrap: code-server install, extension management, mTLS, settings sync |
| `devcontainer/extensions/` | Baked `.vsix` files for offline install |
| `devcontainer/config/nginx-mtls.conf` | NGINX mTLS reverse proxy for code-server |
| `desktop/desktop-entrypoint.sh` | Desktop session bootstrap |
| `desktop/agents/` | Agent-specific entrypoints (Claude, OpenClaw, generic) |
| `desktop/config/` | supervisord, Selkies, theme, Xvfb configs |
| `common/setup-tls.sh` | Decode TLS certs from env vars |
| `seccomp-sandbox.json` | Syscall allowlist (amd64 + arm64) |
