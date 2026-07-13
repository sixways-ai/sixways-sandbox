# Desktop sandbox image for SixWays.
# Provides a full Linux desktop environment with WebRTC streaming (Selkies-
# GStreamer) inside a sandboxed container, monitored by eBPF. AI agents
# (Claude Computer Use, OpenClaw, etc.) are installed at runtime via agent
# entrypoint scripts.
#
# Based on the Selkies-GStreamer example container which provides:
# - Xvfb + Xfce4 desktop environment
# - WebRTC streaming with audio (PulseAudio + Opus)
# - supervisord process management
#
# TURN relay runs on the host (embedded in sixwaysd), NOT in this container.
# This avoids Docker Desktop's unreliable UDP port forwarding.
#
# Build context: repo root (so COPY uses desktop/ prefix)
#   docker build -t sixways-sandbox:desktop -f desktop/Dockerfile .

ARG SELKIES_IMAGE=ghcr.io/selkies-project/selkies-gstreamer/gst-py-example
ARG SELKIES_TAG=latest
# Pinned to a specific digest for supply-chain integrity — the build always
# pulls exactly these bytes regardless of where :latest points. The Selkies base
# is amd64-only (single-platform). Bump deliberately: re-resolve the tag
#   oras resolve ghcr.io/selkies-project/selkies-gstreamer/gst-py-example:latest
# and update the digest below. Override with --build-arg SELKIES_DIGEST=… (or
# set it empty to fall back to SELKIES_TAG).
ARG SELKIES_DIGEST=sha256:0a264d017c682011c01f8fe94c656f9d5db6afac9b1b6a1647a24391a2362974
# Resolve the base ref in two steps so FROM stays a plain substitution and the
# digest-or-tag toggle actually works. A single-line
# ${SELKIES_DIGEST:+...}${SELKIES_DIGEST:-...} is broken: the :- arm returns the
# digest VALUE when the digest is set, doubling it into an invalid reference
# ("IMAGE@sha256:..sha256:.."). Here: SELKIES_DIGEST set -> IMAGE@DIGEST; empty
# -> IMAGE:TAG.
ARG SELKIES_REF=${SELKIES_DIGEST:+${SELKIES_IMAGE}@${SELKIES_DIGEST}}
ARG SELKIES_REF=${SELKIES_REF:-${SELKIES_IMAGE}:${SELKIES_TAG}}
FROM ${SELKIES_REF}

ARG IMAGE_VERSION=dev
ENV SIXWAYS_IMAGE_VERSION=${IMAGE_VERSION}

USER 0

# --- Additional packages ---
# The gst-py-example base includes: xfce4, firefox, Xvfb, selkies-gstreamer,
# GStreamer, PulseAudio libs. We add process management, audio, networking,
# theming, and developer tools.
RUN apt-get update && apt-get install -y --no-install-recommends \
    supervisor \
    pulseaudio \
    mousepad \
    arc-theme \
    papirus-icon-theme \
    git \
    curl \
    wget \
    nodejs \
    npm \
    build-essential \
    nginx \
    ffmpeg \
    zip \
    unzip \
    p7zip-full \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# --- Security remediation ---
# The upstream Selkies base ships Pillow 9.1.0, which has CVE-2023-50447
# (PIL.ImageMath.eval arbitrary code execution; CRITICAL; fixed in 10.2.0). We
# do not use Pillow directly, so force-upgrade it in place in the Selkies Python
# env (3.8) so the published image carries no CRITICAL CVE.
RUN { python3.8 -m pip install --no-cache-dir --upgrade 'Pillow>=10.2.0' \
      || python3 -m pip install --no-cache-dir --upgrade 'Pillow>=10.2.0'; } \
    && { python3.8 -c 'import PIL; print("Pillow", PIL.__version__)' \
         || python3 -c 'import PIL; print("Pillow", PIL.__version__)'; }

# --- Sandbox user ---
# The base image uses uid 1000 "ubuntu". Keep that user.
# Limited sudo for package installation only.
RUN echo "ubuntu ALL=(root) NOPASSWD: /usr/bin/dpkg, /usr/bin/apt-get" \
       > /etc/sudoers.d/sandbox-install \
    && chmod 440 /etc/sudoers.d/sandbox-install

# --- Entrypoints and config ---
COPY desktop/desktop-entrypoint.sh /desktop-entrypoint.sh
COPY desktop/agents/ /agents/
COPY desktop/config/apply-theme.sh /opt/sixways/apply-theme.sh
COPY desktop/config/start-xvfb.sh /opt/sixways/start-xvfb.sh
COPY desktop/config/start-selkies.sh /opt/sixways/start-selkies.sh
COPY desktop/config/nginx-mtls.conf /etc/sixways/nginx-mtls.conf
COPY common/setup-tls.sh /opt/sixways/setup-tls.sh
COPY desktop/config/supervisord.conf /etc/supervisord.conf

RUN chmod +x /desktop-entrypoint.sh /agents/*.sh /opt/sixways/*.sh
RUN chmod 644 /etc/supervisord.conf
RUN mkdir -p /etc/supervisor/conf.d /tmp/runtime-ubuntu/pulse /tmp/.X11-unix /etc/sixways/tls \
        /var/lib/nginx/body /var/lib/nginx/proxy /var/lib/nginx/fastcgi \
        /var/lib/nginx/uwsgi /var/lib/nginx/scgi \
    && chown -R 1000:1000 /tmp/runtime-ubuntu /tmp/.X11-unix /etc/sixways/tls \
        /var/lib/nginx /var/log/nginx \
    && chmod 1777 /tmp/.X11-unix

# Patch Selkies for containerized deployment:
# Force relay mode so all WebRTC traffic goes through the host-side TURN relay.
# This avoids mDNS resolution failures when running inside Docker.
# TURN transport stays as UDP (the relay runs natively on the host, not in Docker).
RUN SELKIES_PY="/usr/local/lib/python3.8/dist-packages/selkies_gstreamer/__main__.py" && \
    if [ -f "$SELKIES_PY" ]; then \
        sed -i 's/"iceTransportPolicy": "all"/"iceTransportPolicy": "relay"/g' "$SELKIES_PY"; \
    fi && \
    if [ -f /opt/gst-web/webrtc.js ]; then \
        sed -i 's/"iceTransportPolicy": "all"/"iceTransportPolicy": "relay"/' /opt/gst-web/webrtc.js; \
    fi

# --- Brokered git plumbing (WI-SB-01, spec 5.4) ---
# Mirrors base/Dockerfile: the endpoint bind-mounts the host-side broker
# shim READ-ONLY at /usr/local/bin/sixways-git-shim and injects hermetic
# GIT_CONFIG_* env at launch. Env beats system scope, so these entries
# complement, never fight, the launch env. Guarded wrappers delegate to the
# shim when mounted; standalone the credential wrapper vends nothing and
# the signing wrapper falls back to the real ssh-keygen. core.hooksPath is
# deliberately NOT set (endpoint-owned via env). The Selkies base is
# third-party, so the build also asserts no stored-credential manager
# (git-credential-manager) and no url.*.insteadOf rewrite ships in the
# image.
COPY --chmod=755 common/git-credential-sixways /opt/sixways/git-credential-sixways
COPY --chmod=755 common/git-ssh-sign-sixways /opt/sixways/git-ssh-sign-sixways
RUN git config --system credential.helper /opt/sixways/git-credential-sixways \
    && git config --system gpg.format ssh \
    && git config --system gpg.ssh.program /opt/sixways/git-ssh-sign-sixways \
    && ! command -v git-credential-manager \
    && ! command -v git-credential-manager-core \
    && ! git config --system --get core.hooksPath \
    && ! git config --system --list | grep -qi insteadof

# --- GStreamer paths (from Selkies base image) ---
ENV PATH="/opt/gstreamer/bin:${PATH}"
ENV LD_LIBRARY_PATH="/opt/gstreamer/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH}"
ENV GI_TYPELIB_PATH="/opt/gstreamer/lib/x86_64-linux-gnu/girepository-1.0:/usr/lib/x86_64-linux-gnu/girepository-1.0"
ENV PYTHONPATH="/opt/gstreamer/lib/python3.8/site-packages:/opt/gstreamer/lib/python3/dist-packages:${PYTHONPATH}"

# --- Environment defaults ---
ENV DISPLAY=:20
ENV DISPLAY_WIDTH=1920
ENV DISPLAY_HEIGHT=1080
ENV SELKIES_ENCODER=x264enc
ENV SELKIES_ENABLE_RESIZE=false
ENV SELKIES_ENABLE_BASIC_AUTH=false
ENV SELKIES_BASIC_AUTH_USER=ubuntu
ENV SELKIES_BASIC_AUTH_PASSWORD=password
ENV SELKIES_TURN_PASSWORD=turnpassword
ENV GST_DEBUG=*:2
ENV XDG_RUNTIME_DIR=/tmp/runtime-ubuntu
ENV PULSE_SERVER=unix:/tmp/runtime-ubuntu/pulse/native

# Selkies WebRTC streaming port (NGINX mTLS termination)
EXPOSE 8081

USER 1000
ENV SHELL=/bin/bash
ENV USER=ubuntu
ENV HOME=/home/ubuntu
WORKDIR /home/ubuntu

# supervisord manages: Xvfb, Xfce4, PulseAudio, Selkies, Agent
ENTRYPOINT ["/usr/bin/supervisord", "-c", "/etc/supervisord.conf"]
