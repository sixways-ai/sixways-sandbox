# sixways-sandbox

Hardened container images for AI coding agent sandboxing.
Published to `ghcr.io/sixways-ai/sixways-sandbox`.

## Variants

### Container variants (Docker-delivered)

| Tag | Contents | Size |
|-----|----------|------|
| `base` | git + bash + ssh client + curl/wget + jq + ripgrep + rsync + netcat + gawk | ~30 MB |
| `node` | base + Node.js 22 LTS + npm | ~80 MB |
| `python` | base + Python 3.12 + pip | ~60 MB |
| `devcontainer` | node + VSCode Dev Container support | ~100 MB |
| `desktop` | Selkies-GStreamer + Xfce4 + NGINX mTLS proxy | ~2.7 GB |

### microVM variants (premium SKU, no Docker on customer hosts)

Same Wolfi base, same apk surface as the container variants; the
delivery format is a signed `.ext4` shipped via `sixways-update` and
booted by the host VMM (libkrun on macOS/Linux, QEMU+WHPX on Windows).
microVM variants are part of the premium SixWays offering and are not
built from this open-source repository.

| Tag | Contents | Size |
|-----|----------|------|
| `microvm-base`   | Wolfi + same tool surface as `:base` (minus sshd) + `sixways-sandbox-init` + `sixways-mcp-proxy` | ~30 MB |
| `microvm-node`   | `microvm-base` + Node.js 22 LTS + npm | ~80 MB |
| `microvm-python` | `microvm-base` + Python 3.12 + pip | ~60 MB |

## Quick start

The in-container sshd was retired (SixWays #560): the image ships no listening
service. Start a container (it idles via `sleep infinity`) and attach with
`docker exec`. SixWays itself launches agents by overriding the entrypoint, and
"ssh into the sandbox" is served by the governed SSH bridge in the SixWays
daemon.

```bash
# Start a sandbox container (idles, ready for exec)
cid=$(docker run -d ghcr.io/sixways-ai/sixways-sandbox:base)

# Attach a shell
docker exec -it "$cid" bash
```

For the Node.js variant, replace `:base` with `:node`. For Python, use `:python`. For Dev Containers, use `:devcontainer`. For the desktop GUI sandbox, use `:desktop`.

## Security design

- **Wolfi base** - minimal, CVE-tracked OS built for containers
- **Non-root sandbox user** - uid 1000, no privilege escalation path
- **No sudo** - removed at image build time to reduce escape surface
- **No in-container sshd** - the listening SSH server was retired (SixWays #560); CLI containers expose no listening service. The agent is launched and reached over `docker exec`, and governed interactive access is the SixWays daemon's SSH bridge. Only an `ssh` client remains, for git-over-ssh.
- **seccomp profile** - default-deny syscall filter (`seccomp-sandbox.json`) with explicit allowlist for git, ssh-client, and build tools
- **NGINX mTLS proxy** - IDE and Desktop profiles use an NGINX reverse proxy with mutual TLS (client certificate authentication) to secure code-server and Selkies-GStreamer web endpoints; only clients presenting a valid certificate can connect

## Recommended runtime flags

For maximum isolation, run containers with these flags:

```bash
docker run -d \
  --cap-drop=ALL \
  --read-only \
  --tmpfs /tmp \
  --tmpfs /run \
  -v sandbox-workspace:/workspace \
  -v sandbox-home:/home/sandbox \
  --network none \
  --security-opt seccomp=seccomp-sandbox.json \
  ghcr.io/sixways-ai/sixways-sandbox:base
```

Attach with `docker exec -it <container> bash`.

| Flag | Purpose |
|------|---------|
| `--cap-drop=ALL` | Drop all Linux capabilities - the sandbox needs none |
| `--read-only` | Prevent modification of system binaries and config |
| `--tmpfs /tmp --tmpfs /run` | Writable scratch areas on a read-only root |
| `-v ...:/workspace` | Persistent writable workspace for the agent |
| `-v ...:/home/sandbox` | Persistent home dir for shell history, npm cache, ssh known_hosts |
| `--network none` | No outbound network access |
| `--security-opt seccomp=seccomp-sandbox.json` | Default-deny syscall filter with allowlist for git, ssh-client, and build tools |

If the agent needs outbound access (e.g. `npm install`, `git clone`), replace `--network none` with a restricted Docker network or firewall rules.

## Running AI coding agents

The sandbox images don't ship with any agent pre-installed - agents are installed at runtime so you always get the latest version. The orchestrator (e.g. SixWays Endpoint) launches the container, installs the agent, and runs it over `docker exec`.

### Claude Code (Anthropic) - uses `:node`

```bash
cid=$(docker run -d ghcr.io/sixways-ai/sixways-sandbox:node)

docker exec -i "$cid" bash -lc '
  npm install -g @anthropic-ai/claude-code
  ANTHROPIC_API_KEY=sk-ant-... claude "fix the failing tests"
'
```

### Codex CLI (OpenAI) - uses `:node`

```bash
docker exec -i "$cid" bash -lc '
  npm install -g @openai/codex
  OPENAI_API_KEY=sk-... codex "refactor the auth module"
'
```

### Gemini CLI (Google) - uses `:node`

```bash
docker exec -i "$cid" bash -lc '
  npm install -g @google/gemini-cli
  GEMINI_API_KEY=... gemini
'
```

### OpenClaw - uses `:node`

```bash
docker exec -i "$cid" bash -lc '
  npm install -g openclaw
  openclaw agent
'
```

### Aider - uses `:python`

```bash
cid=$(docker run -d ghcr.io/sixways-ai/sixways-sandbox:python)

docker exec -i "$cid" bash -lc '
  pip install --user aider-chat
  ANTHROPIC_API_KEY=sk-ant-... aider --model claude-sonnet-4-6
'
```

> **Note:** These examples show API keys inline for clarity. In production, pass keys via environment variables at `docker run` time or mount a secrets file - never hardcode them.

## Dev Container usage

The `devcontainer` variant is designed for running AI agent extensions (Copilot, Claude Code, Cline, etc.) inside VSCode, Cursor, or Windsurf Dev Containers with endpoint monitoring. It builds on the node variant and adds the packages VSCode needs to bootstrap its Extension Host inside the container.

Add a `.devcontainer/devcontainer.json` to your project:

```json
{
  "image": "ghcr.io/sixways-ai/sixways-sandbox:devcontainer",
  "customizations": {
    "vscode": {
      "extensions": [
        "sixways.endpoint"
      ]
    }
  },
  "remoteUser": "sandbox",
  "workspaceFolder": "/workspace"
}
```

The container stays alive via `sleep infinity` and VSCode attaches via `docker exec`. code-server serves the browser IDE; there is no in-container sshd (retired, SixWays #560).

## Building locally

The variant Dockerfiles inherit from `ghcr.io/sixways-ai/sixways-sandbox`. To build entirely from source, tag images with the GHCR name so derived builds resolve locally:

**Linux / macOS / WSL:**

```bash
# Build base image (tag it as the GHCR name so variants resolve locally)
docker build -t sixways-sandbox:base \
  -t ghcr.io/sixways-ai/sixways-sandbox:latest \
  -f base/Dockerfile .

# Build node variant (tag with GHCR name so devcontainer resolves locally)
docker build -t sixways-sandbox:node \
  -t ghcr.io/sixways-ai/sixways-sandbox:node \
  -f node/Dockerfile node/

# Build python variant
docker build -t sixways-sandbox:python -f python/Dockerfile python/

# Build devcontainer variant
docker build -t sixways-sandbox:devcontainer -f devcontainer/Dockerfile .

# Build desktop variant (Ubuntu-based, standalone)
docker build -t sixways-sandbox:desktop -f desktop/Dockerfile desktop/
```

**Windows (PowerShell):**

```powershell
docker build -t sixways-sandbox:base -t ghcr.io/sixways-ai/sixways-sandbox:latest -f base/Dockerfile .
docker build -t sixways-sandbox:node -t ghcr.io/sixways-ai/sixways-sandbox:node -f node/Dockerfile node/
docker build -t sixways-sandbox:python -f python/Dockerfile python/
docker build -t sixways-sandbox:devcontainer -f devcontainer/Dockerfile .
docker build -t sixways-sandbox:desktop -f desktop/Dockerfile desktop/
```

## Project structure

```
base/Dockerfile             # Wolfi-based minimal image with git + bash + ssh client
node/Dockerfile             # Inherits base, adds Node.js 22 LTS
python/Dockerfile           # Inherits base, adds Python 3.12
devcontainer/Dockerfile     # Inherits node, adds VS Code Dev Container support
desktop/Dockerfile          # Ubuntu-based, Selkies-GStreamer + Xfce4 + NGINX mTLS
desktop/desktop-entrypoint.sh  # Desktop session bootstrap (Xvfb, Selkies, NGINX)
desktop/config/             # NGINX mTLS config, supervisord, Selkies startup scripts
entrypoint.sh               # Passthrough: exec "$@" or idle (sleep infinity) for docker exec
```

## Publishing & image freshness

Images are rebuilt, scanned, tested, signed, and published to GHCR on a weekly
cadence, plus on demand.

| Trigger | When | Purpose |
|---------|------|---------|
| **Scheduled** | Weekly, every Monday | Rebuild on the latest packages so CVE fixes from Wolfi, Node, and Python land automatically |
| **Manual** | On demand | Out-of-cycle rebuild (e.g. after a base-image bump) |

Every publish runs the same gates before any tag moves:

1. **Package freshness** — each build runs `apk upgrade` / `apk add --no-cache`, pulling the latest Wolfi package versions at build time.
2. **Base-image freshness** — the base images are digest-pinned for reproducibility; [`scripts/refresh-base-digests.sh`](scripts/refresh-base-digests.sh) re-resolves those pins to the latest upstream (`--check` reports drift, `--write` bumps them).
3. **Vulnerability gate** — Trivy fails the build on CRITICAL/HIGH CVEs.
4. **Sanity/regression gate** — [`tests/test-sandbox-images.sh`](tests/test-sandbox-images.sh) verifies the built images still hold their contract (tools present, runtimes at the expected major, no `sudo`/`su`, entrypoint idles / passes through, brokered-git plumbing intact: guarded credential/signing wrappers still point at the endpoint's `sixways-git-shim` mount path, no `git-credential-manager` in the image, no `insteadOf` rewrites, `core.hooksPath` left to the endpoint, git recent enough for ssh signing) before anything is signed or promoted.
5. **Signed publish** — images are pushed by digest, signed, verified, and only then are the canonical tags promoted (atomically), so a failed run never leaves a consumer-facing tag unsigned.

To refresh and republish out of cycle:

```bash
scripts/refresh-base-digests.sh --write     # bump stale base pins (if any)
./build.sh                                   # rebuild the variants
tests/test-sandbox-images.sh                 # sanity gate — must pass before publishing
```

## Testing

Automated sanity/regression suite — run it after building and before publishing:

```bash
# Build the variants first (see "Building locally"), then:
tests/test-sandbox-images.sh                 # base node python devcontainer
tests/test-sandbox-images.sh all             # + desktop
```

It starts each variant and asserts the security + tooling contract: the
non-root `sandbox` user (uid 1000) exists, `sudo`/`su` are gone, the expected
tools and runtime majors (Node 22, Python 3.12) are present, `/workspace` is
sandbox-owned, the entrypoint idles / passes commands through, and the
brokered-git plumbing holds (system `credential.helper` / `gpg.ssh.program`
point at the guarded wrappers, the wrappers target
`/usr/local/bin/sixways-git-shim`, no credential manager or `insteadOf`
rewrite is baked, `core.hooksPath` is unset, and a fake-shim mount proves the
delegation path). Point it at
other tags with `TAG_PREFIX=…` or `IMAGE_<VARIANT>=…` (CI runs it against its
scan images). Any failure exits non-zero — do not publish.

Quick manual smoke test:

```bash
cid=$(docker run -d sixways-sandbox:base)
docker exec -it "$cid" bash
which sudo  # should fail
docker rm -f "$cid"
```

## Customizing

To add language runtimes or tools, create a new `Dockerfile` in a subdirectory that inherits from the base image:

```dockerfile
ARG BASE_TAG=latest
FROM ghcr.io/sixways-ai/sixways-sandbox:${BASE_TAG}

RUN apk add --no-cache python-3
```

Keep additions minimal - every binary is a potential escape vector.

## License

Apache 2.0 - see [LICENSE](LICENSE).
