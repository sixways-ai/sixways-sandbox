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
# TODO: pin to specific digest for production builds
# Usage: docker build --build-arg SELKIES_DIGEST=sha256:abc123... -f desktop/Dockerfile .
ARG SELKIES_DIGEST=
FROM ${SELKIES_DIGEST:+${SELKIES_IMAGE}@${SELKIES_DIGEST}}${SELKIES_DIGEST:-${SELKIES_IMAGE}:${SELKIES_TAG}}

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
