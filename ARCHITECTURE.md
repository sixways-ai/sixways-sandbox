# SixWays Sandbox Architecture

Hardened container images for AI agent sandboxing.

## High-level design

SixWays Sandbox provides minimal, security-hardened container images built on Wolfi.
CLI containers have no listening service. SixWays launches and reaches agents through
`docker exec`, while the daemon's governed SSH bridge provides interactive access. The
in-container sshd was retired in SixWays #560. Agents are installed at runtime
instead of being included in the images. The first release builds and publishes
base/node/python/rust/go CLI images. Premium microVM images retain their separate
base/node/python build and signed disk-image delivery workflow. Hosted IDE and
desktop source is deferred and excluded from defaults, release workflows and
public snapshots. External VS Code integration remains separate.

## Project structure

```
base/Dockerfile        # Wolfi-based minimal image with git + bash + ssh client
node/Dockerfile        # Inherits base; retained as the Node project tag
python/Dockerfile      # Inherits base; retained as the Python project tag
rust/Dockerfile        # Inherits base, adds rustc and cargo
go/Dockerfile          # Inherits base, adds the Go toolchain
devcontainer/Dockerfile # Deferred hosted IDE source; excluded from release
desktop/Dockerfile     # Deferred desktop source; excluded from release
desktop/desktop-entrypoint.sh  # Desktop session bootstrap (Xvfb, Selkies, NGINX)
desktop/config/        # NGINX mTLS config, supervisord, Selkies startup scripts
entrypoint.sh          # Passthrough: exec "$@" or idle (sleep infinity) for docker exec
```

## Main components

- **Release image hierarchy:** `base` -> `node` / `python` / `rust` / `go`. Deferred hosted IDE source inherits `node`; deferred desktop source uses a separate Ubuntu-based image.
- **Native build toolchain:** `base` includes gcc, g++, make, cmake, pkg-config, and binutils through Wolfi's `build-base`. Every variant inherits these tools. Agents run as uid 1000 without `sudo`, and the strict tier mounts the root filesystem read-only, so agents cannot install missing compilers. Rust, cgo, node-gyp, and Python wheels built from source all depend on this toolchain.
- **Agent runtimes:** `base` includes Node.js 22 with npm and Python 3.12 with pip and development headers. SixWays selects images by project language but installs agents at launch, so each image must support every agent runtime. For example, Claude Code still requires Node.js when it runs against a Rust project in the `:rust` image. The `:node` and `:python` images add no packages to `base`; they remain published tags used for project-language selection.
- **Privilege controls:** `sudo` and all setuid-root binaries are absent. The endpoint requires the non-setuid BusyBox `su` applet to switch from root to the sandbox user during startup. The locked root password and lack of a setuid bit prevent uid 1000 from using this applet to become root. The regression suite tests both the startup operation and the inability to elevate privileges.
- **Seccomp:** `seccomp-sandbox.json` provides a default-deny syscall filter with an explicit allowlist for Git, the SSH client, and build tools.
- **Supply chain:** Base images are pinned by SHA-256 digest for reproducible builds.
- **Deferred NGINX mTLS proxy:** retained IDE and Desktop implementations run an NGINX reverse proxy with mutual TLS client authentication. Code-server and Selkies-GStreamer bind only to localhost; NGINX terminates TLS and verifies the client certificate before proxying requests.
- **Deferred desktop streaming:** the retained Desktop source uses Selkies-GStreamer to stream an Xfce4 session over WebRTC through the NGINX mTLS proxy.

## Cross-repository dependencies

- **sixways-endpoint** uses these images in container sandbox mode.
- The external **sixways-ide-extension-dev** integration has its own build and release. Sandbox image builds no longer compile or embed its VSIX.

## Design decisions

- **Wolfi over Alpine:** Wolfi provides more detailed CVE tracking and a predictable patch process for security-sensitive workloads.
- **Exec over an in-container sshd:** SixWays reaches CLI containers through `docker exec` and the daemon's governed SSH bridge, so the image does not run sshd.
- **No pre-installed agents:** Installing agents at runtime avoids stale agent binaries and reduces image rebuild frequency.
- **Planned**: eBPF sidecar for kernel-level visibility inside containers.

## See also

- [System Overview](https://github.com/sixways-ai/architecture/blob/main/docs/system-overview.md)
- [Repository Map](https://github.com/sixways-ai/architecture/blob/main/docs/repo-map.md)
- [Endpoint Modes](https://github.com/sixways-ai/architecture/blob/main/docs/concepts/endpoint-modes.md)
