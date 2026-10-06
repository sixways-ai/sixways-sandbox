# sixways-sandbox

Hardened container images for AI coding agent sandboxing.
Release automation targets `ghcr.io/sixways-ai/sixways-sandbox`.

The first release provides CLI sessions through `base`, `node`, `python`, `rust`
and `go`. Existing premium microVM image variants remain on their separate build
and signed disk-image delivery path. Hosted code-server IDE and Selkies/Xfce
desktop sessions are deferred; their source remains in the private development
repository but is excluded from default builds, release workflows and public
source snapshots. The external SixWays VS Code extension remains a separate
integration and release; these image builds do not package it.

## Variants

### Container variants (Docker-delivered)

| Tag | Contents | Size |
|-----|----------|------|
| `base` | git + bash + ssh client + curl/wget + jq + ripgrep + rsync + netcat + gawk, the native build toolchain (gcc, g++, make, cmake, pkg-config, binutils), **and both agent runtimes** (Node.js 22 + npm, Python 3.12 + pip + `Python.h` + setuptools/wheel) | ~295 MB |
| `node` | base. The Node runtime is inherited from `base`; this tag marks a Node **project** | ~295 MB |
| `python` | base. The Python runtime is inherited from `base`; this tag marks a Python **project** | ~295 MB |
| `rust` | base + rustc + cargo | ~455 MB |
| `go` | base + Go toolchain (cgo enabled) | ~345 MB |

### Why the build toolchain is baked in

The sandbox has no `sudo`, uses a read-only root filesystem on the strict tier, and
runs the agent as uid 1000. An agent cannot install a compiler at runtime: `apk add`
fails with "Read-only file system," and `sudo apk add` fails with "sudo: command not
found." The image must therefore include the compilers needed by common workflows.

Without the build toolchain:

- `npm install` fails for every package with a native addon (node-gyp runs
  `make` and `g++`): better-sqlite3, bcrypt, canvas, and anything lacking a prebuilt
  binary for the target platform. node-gyp also needs a Python 3 interpreter because
  gyp itself is a Python program.
- `pip install` fails for every wheel built from source (psycopg2, lxml). Compiling
  a C extension also needs `Python.h`, which the `-dev` package provides but the
  runtime Python package does not.
- Rust and Go do not link on their own: `rustc` drives the system `cc`, and `cgo` needs
  `gcc`. Both variants depend on the toolchain in `base`.

### Why both agent runtimes are baked into `base`

SixWays installs the selected agent when the container starts instead of including
agents in the images. The installation runs as uid 1000 on a read-only root filesystem
and uses commands such as `npm install -g @anthropic-ai/claude-code` and `pip install
--user omnigent`. The required interpreter must already be in the image or the agent
cannot start.

SixWays selects an image based on the project's language, while the agent determines
the required runtime. These are independent choices:

- 11 of the built-in agents are Node-runtime, including the flagship, Claude Code.
- Several are pip-installed (Omnigent, Aider).
- A Rust project running Claude Code gets `:rust`, so `npm install -g` must work in
  that image as well.

If runtimes were limited to matching language variants, each combination of project
language and agent runtime would need separate handling. A previous `:rust` image built
on a base without runtimes had no `node` binary, so it could not launch Claude Code.

The `base` image now includes both runtimes, and every variant inherits them. Each
CLI release candidate must pass both runtime checks; agent compatibility depends
on its required runtime, while image selection follows the project language.
This adds about 65 MB to `base` and does not change the size of `:node`.

### microVM variants (premium SKU, no Docker on customer hosts)

Same pinned Wolfi base with a smaller, guest-specific package surface; the
delivery format is a signed `.ext4` shipped via `sixways-update` and
booted by the host VMM (libkrun on macOS/Linux, QEMU+WHPX on Windows).
microVM variants are part of the premium SixWays offering and are not
built from this open-source repository.

| Tag | Contents | Size |
|-----|----------|------|
| `microvm-base`   | Wolfi guest tools + `sixways-sandbox-init` + `sixways-mcp-proxy` + `sixways-microvm-ebpf-agent` | ~30 MB |
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
docker exec -u sandbox -it "$cid" bash
```

For the Node.js variant, replace `:base` with `:node`. For Python, use `:python`. For
Rust, use `:rust`. For Go, use `:go`.

## Security design

- **Wolfi base:** Minimal, CVE-tracked OS built for containers
- **Non-root sandbox user:** uid 1000 with no privilege escalation path
- **No sudo:** Removed at image build time to eliminate a path to root
- **No in-container sshd:** The listening SSH server was retired (SixWays #560), so CLI containers expose no listening service. SixWays launches agents over `docker exec` and provides governed interactive access through the daemon's SSH bridge. An `ssh` client remains for git-over-ssh.
- **seccomp profile:** Default-deny syscall filter (`seccomp-sandbox.json`) with an explicit allowlist for git, the SSH client, and build tools

## Recommended runtime flags

For maximum isolation, run containers with these flags:

```bash
docker run -d \
  --cap-drop=ALL \
  --cap-add=CHOWN --cap-add=DAC_OVERRIDE --cap-add=FOWNER \
  --cap-add=SETUID --cap-add=SETGID --cap-add=SETPCAP \
  --cap-add=FSETID --cap-add=KILL \
  --read-only \
  --tmpfs /tmp:rw,nosuid,nodev,exec,size=256m \
  --tmpfs /run:rw,nosuid,nodev,exec,size=128m \
  -v sandbox-workspace:/workspace \
  -v sandbox-home:/home/sandbox \
  --network none \
  --security-opt no-new-privileges:true \
  --security-opt seccomp=seccomp-sandbox.json \
  ghcr.io/sixways-ai/sixways-sandbox:base
```

Attach with `docker exec -u sandbox -it <container> bash`. The image retains a
root `Config.User` only because the SixWays endpoint overrides the entrypoint
with a root bootstrap; the default entrypoint itself drops PID 1 to uid 1000.

| Flag | Purpose |
|------|---------|
| `--cap-drop=ALL` + allowlist | Retain only the capabilities needed for root-to-uid-1000 bootstrap and mounted-directory ownership |
| `--read-only` | Prevent modification of system binaries and config |
| `--tmpfs /tmp --tmpfs /run` | Writable scratch areas on a read-only root |
| `-v ...:/workspace` | Persistent writable workspace for the agent |
| `-v ...:/home/sandbox` | Persistent home dir for shell history, npm cache, ssh known_hosts |
| `--network none` | No outbound network access |
| `--security-opt no-new-privileges:true` | Prevent execution from gaining new privileges |
| `--security-opt seccomp=seccomp-sandbox.json` | Default-deny syscall filter with allowlist for git, ssh-client, and build tools |

If the agent needs outbound access (e.g. `npm install`, `git clone`), replace `--network none` with a restricted Docker network or firewall rules.

## Running AI coding agents

The sandbox images do not include agents. The orchestrator, such as SixWays Endpoint,
starts the container, installs the selected agent at runtime, and runs it over `docker
exec`.

### Claude Code (Anthropic) - uses `:node`

```bash
cid=$(docker run -d ghcr.io/sixways-ai/sixways-sandbox:node)

docker exec -u sandbox -i "$cid" bash -lc '
  npm install -g @anthropic-ai/claude-code
  ANTHROPIC_API_KEY=sk-ant-... claude "fix the failing tests"
'
```

### Codex CLI (OpenAI) - uses `:node`

```bash
docker exec -u sandbox -i "$cid" bash -lc '
  npm install -g @openai/codex
  OPENAI_API_KEY=sk-... codex "refactor the auth module"
'
```

### Gemini CLI (Google) - uses `:node`

```bash
docker exec -u sandbox -i "$cid" bash -lc '
  npm install -g @google/gemini-cli
  GEMINI_API_KEY=... gemini
'
```

### OpenClaw - uses `:node`

```bash
docker exec -u sandbox -i "$cid" bash -lc '
  npm install -g openclaw
  openclaw agent
'
```

### Aider - uses `:python`

```bash
cid=$(docker run -d ghcr.io/sixways-ai/sixways-sandbox:python)

docker exec -u sandbox -i "$cid" bash -lc '
  pip install --user aider-chat
  ANTHROPIC_API_KEY=sk-ant-... aider --model claude-sonnet-4-6
'
```

> **Note:** These examples show API keys inline for clarity. In production, pass keys via environment variables at `docker run` time or mount a secrets file - never hardcode them.

### sixways-mcp-proxy in the CLI images

Every CLI image carries `/usr/local/bin/sixways-mcp-proxy`, the static musl MCP governance
wrapper from `sixways-endpoint-dev` (`crates/sixways-mcp-proxy`, built `--no-default-features`,
stdio MCP servers only). The binaries are not committed. `common/mcp-proxy/PROVENANCE` pins the
source commit and rustc, `common/mcp-proxy/SHA256SUMS` pins each architecture, and
`scripts/build-mcp-proxy.sh <endpoint-checkout>` builds both binaries (the checkout must be at the
pinned commit) and fails on any checksum mismatch. The publish workflow, the CI image builds and
`build.sh` run it before `docker build`; `base/Dockerfile` verifies the checksum again and fails the
build on mismatch. The endpoint bind-mounts its own proxy over this path when MCP governance is on;
the baked copy serves plain `docker run`. To update: change `source_commit` (and `rustc`) in
`PROVENANCE`, run the script with `--update`, and commit `PROVENANCE` and `SHA256SUMS`.

### sixways-probe in the CLI images

Every CLI image also carries `/usr/local/bin/sixways-probe`, the std-only static musl client of the
runtime policy canary probe (`sixways-endpoint-dev` `crates/sixways-probe`; contract
`architecture/docs/protocols/runtime-policy-probe.md`). It makes two HTTP GETs, one the applied
policy must deny and one it must allow, and has no other capability: no files, no spawn, a fixed
argv. The managed policy's reserved `sixways_probe_allow` rule lists this path (and the `/tmp`
fallback path the connector delivers to for images that lack it). It is pinned and built exactly
like the proxy: `common/probe/PROVENANCE`, `common/probe/SHA256SUMS` (one digest per architecture),
`scripts/build-probe.sh <endpoint-checkout>`. The binaries are not committed. Update by changing
`source_commit` in `PROVENANCE` and running the script with `--update`.

## Building locally

The variant Dockerfiles inherit from `ghcr.io/sixways-ai/sixways-sandbox`. To build entirely from source, tag images with the GHCR name so derived builds resolve locally:

**Linux / macOS / WSL:**

```bash
# Build base image (tag it as the GHCR name so variants resolve locally)
docker build -t sixways-sandbox:base \
  -t ghcr.io/sixways-ai/sixways-sandbox:latest \
  -f base/Dockerfile .

# Build node variant
docker build --build-arg BASE_IMAGE=sixways-sandbox:base -t sixways-sandbox:node \
  -t ghcr.io/sixways-ai/sixways-sandbox:node \
  -f node/Dockerfile .

# Build python variant
docker build --build-arg BASE_IMAGE=sixways-sandbox:base -t sixways-sandbox:python -f python/Dockerfile .

# Build rust + go variants
docker build --build-arg BASE_IMAGE=sixways-sandbox:base -t sixways-sandbox:rust -f rust/Dockerfile .
docker build --build-arg BASE_IMAGE=sixways-sandbox:base -t sixways-sandbox:go -f go/Dockerfile .

```

**Windows (PowerShell):**

```powershell
docker build -t sixways-sandbox:base -t ghcr.io/sixways-ai/sixways-sandbox:latest -f base/Dockerfile .
docker build --build-arg BASE_IMAGE=sixways-sandbox:base -t sixways-sandbox:node -t ghcr.io/sixways-ai/sixways-sandbox:node -f node/Dockerfile .
docker build --build-arg BASE_IMAGE=sixways-sandbox:base -t sixways-sandbox:python -f python/Dockerfile .
docker build --build-arg BASE_IMAGE=sixways-sandbox:base -t sixways-sandbox:rust -f rust/Dockerfile .
docker build --build-arg BASE_IMAGE=sixways-sandbox:base -t sixways-sandbox:go -f go/Dockerfile .
```

## Project structure

```
base/Dockerfile             # Wolfi base: git + bash + ssh client + native build toolchain
node/Dockerfile             # Inherits base; retained as the Node project tag
python/Dockerfile           # Inherits base; retained as the Python project tag
rust/Dockerfile             # Inherits base, adds rustc + cargo
go/Dockerfile               # Inherits base, adds the Go toolchain
entrypoint.sh               # Drops to uid 1000, then execs "$@" or idles
common/mcp-proxy/           # PROVENANCE + SHA256SUMS for the baked sixways-mcp-proxy (binaries are built, not committed)
scripts/build-mcp-proxy.sh  # Builds + verifies those binaries from a sixways-endpoint-dev checkout
common/probe/             # PROVENANCE + SHA256SUMS for the baked sixways-probe (binaries are built, not committed)
scripts/build-probe.sh    # Builds + verifies those binaries from a sixways-endpoint-dev checkout
```

## Publishing & image freshness

The CLI image publish workflow rebuilds, scans, tests, signs, and publishes every
week and on demand. A configured workflow is not release qualification evidence.

| Trigger | When | Purpose |
|---------|------|---------|
| **Scheduled** | Every Monday | Rebuild with the latest packages to include CVE fixes from Wolfi, Node, and Python |
| **Manual** | On demand | Out-of-cycle rebuild (e.g. after a base-image bump) |

Every publish runs the same gates before any tag moves:

1. **Package freshness** — each build runs `apk upgrade` / `apk add --no-cache`, pulling the latest Wolfi package versions at build time.
2. **Base-image freshness** — the base images are digest-pinned for reproducibility; [`scripts/refresh-base-digests.sh`](scripts/refresh-base-digests.sh) re-resolves those pins to the latest upstream (`--check` reports drift, `--write` bumps them).
3. **Vulnerability gate** — Trivy pulls and scans each exact pushed platform manifest (amd64 and arm64) before signing.
4. **Sanity/regression gate** — [`tests/test-sandbox-images.sh`](tests/test-sandbox-images.sh) verifies the exact scan images under the strict runtime policy (tools and runtimes present, no `sudo` or suid-root path, uid-1000 entrypoint, brokered-git plumbing) before anything is signed or promoted.
5. **Signed publish** — images are pushed by digest, signed, verified, and only then are the canonical tags promoted (atomically), so a failed run never leaves a consumer-facing tag unsigned.

To refresh and republish out of cycle:

```bash
scripts/refresh-base-digests.sh --write     # bump stale base pins (if any)
./build.sh                                   # rebuild the variants
tests/test-sandbox-images.sh                 # sanity gate — must pass before publishing
```

## Testing

Run selection tests without Docker or registry access (requires PyYAML 6.0.3):

```bash
python3 tests/test-release-selection.py
```

Run the image sanity and regression suite after building and before publishing:

```bash
# Build the variants first (see "Building locally"), then:
tests/test-sandbox-images.sh                 # base node python rust go
tests/test-sandbox-images.sh all             # same first-release CLI variants
```

It starts each variant and asserts the security + tooling contract: the
default PID 1 runs as the non-root `sandbox` user (uid 1000), `sudo` and all
suid-root paths are gone (the non-suid `su` applet is retained for the endpoint's
root bootstrap to switch to the sandbox user), the expected
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
docker exec -u sandbox -it "$cid" bash
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

Keep additions minimal because each binary adds code that could contain an exploitable
vulnerability.

## License

Apache 2.0. See [LICENSE](LICENSE).
