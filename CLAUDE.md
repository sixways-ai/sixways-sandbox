# SixWays Sandbox

Hardened container images for AI coding agent sandboxing.

## Stack

- **Base**: Wolfi (minimal, CVE-tracked container OS)
- **Build**: Dockerfile (multi-stage)
- **Variants**: base (~30 MB), node (~80 MB), python (~60 MB), devcontainer (~100 MB), desktop (~2.7 GB)

## Build

Use the build scripts (recommended) or run Docker commands manually. See `docs/development.md` for full guide including ARM64 gotchas, clean slate rebuilds, and troubleshooting.

```bash
# One-command build (auto-detects platform, builds extension + full image chain)
./build.sh                # macOS/Linux
build.bat                 # Windows

# Specify platform explicitly
./build.sh arm64          # Apple Silicon
./build.sh amd64          # x86_64

# Clean slate (removes volumes, rebuilds with --no-cache)
./build.sh --clean
./build.sh arm64 --clean
```

The build scripts: build the VS Code extension from `../endpoint-vscode`, copy the `.vsix` into `devcontainer/extensions/`, then build base -> node -> devcontainer with the correct `--platform` flag.

### Manual build (if not using scripts)

```bash
# Build the VS Code extension first (baked into devcontainer image)
cd /path/to/endpoint-vscode && npm run build && npm run package
cp endpoint-0.1.0.vsix /path/to/sixways-sandbox/devcontainer/extensions/

# Build base (tag as GHCR name so variants resolve locally)
docker build --platform linux/arm64 -t sixways-sandbox:base -t ghcr.io/sixways-ai/sixways-sandbox:latest -f base/Dockerfile .

# Build variants
docker build --platform linux/arm64 -t sixways-sandbox:node -t ghcr.io/sixways-ai/sixways-sandbox:node -f node/Dockerfile node/
docker build --platform linux/arm64 -t sixways-sandbox:python -f python/Dockerfile python/
docker build --platform linux/arm64 -t sixways-sandbox:devcontainer -f devcontainer/Dockerfile .
docker build --platform linux/arm64 -t sixways-sandbox:desktop -f desktop/Dockerfile desktop/
```

On x86_64 hosts, replace `--platform linux/arm64` with `--platform linux/amd64` or omit it.

## Test

The in-container sshd was retired (SixWays #560); the base image idles so you
attach with `docker exec`.

```bash
cid=$(docker run -d sixways-sandbox:base)
docker exec -it "$cid" bash
which sudo  # should fail
docker rm -f "$cid"
```

## Architecture

- `base/Dockerfile` -- Wolfi base with git + bash + ssh client (for git-over-ssh)
- `node/Dockerfile` -- Inherits base, adds Node.js 22 LTS
- `python/Dockerfile` -- Inherits base, adds Python 3.12
- `devcontainer/Dockerfile` -- Inherits node, adds VS Code Dev Container support (build context must be repo root)
- `devcontainer/ide-entrypoint.sh` -- Bootstraps code-server (downloaded on first launch, cached in `~/.code-server`); listens on localhost:8080 with `--auth none` (auth handled by NGINX mTLS proxy); pre-install extensions via `IDE_EXTENSIONS` env var
- `desktop/Dockerfile` -- Ubuntu-based, Selkies-GStreamer + Xfce4 + NGINX mTLS proxy
- `desktop/desktop-entrypoint.sh` -- Desktop session bootstrap (Xvfb, Selkies, NGINX)
- `desktop/config/nginx-mtls.conf` -- NGINX reverse proxy config with mutual TLS client certificate verification
- `desktop/config/` -- supervisord, Selkies startup scripts, TLS setup, theme application
- `entrypoint.sh` -- Passthrough: exec's `"$@"` if arguments are passed, else `sleep infinity` so an operator can `docker exec` in. SixWays overrides this entrypoint with its sandbox-init bootstrap.
- `entrypoint-devcontainer.sh` -- Exec's `"$@"` (e.g. `/ide-entrypoint.sh`) if arguments are passed, falling back to `sleep infinity`

## Security Design

- Non-root sandbox user (uid 1000)
- No sudo (removed at build time)
- No in-container sshd (retired, SixWays #560): CLI containers are reached via `docker exec`, and "ssh into the sandbox" is served by the governed SSH bridge in the SixWays daemon
- NGINX mTLS proxy for IDE and Desktop profiles (code-server and Selkies-GStreamer bind to localhost only)
