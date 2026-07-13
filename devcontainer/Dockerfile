# BASE_TAG selects the parent tag on GHCR (default path: .github/workflows/
# docker.yml passes BASE_TAG=node). BASE_IMAGE is the fully-qualified parent
# reference; it defaults to the GHCR ref built from BASE_TAG so the existing
# GHCR workflow is unchanged, but a registry-agnostic build (the signed
# Forgejo workflow) can override it to base off any registry host.
ARG BASE_TAG=node
ARG BASE_IMAGE=ghcr.io/sixways-ai/sixways-sandbox:${BASE_TAG}
FROM ${BASE_IMAGE}

# Image version for update detection (set by CI, defaults to "dev")
ARG IMAGE_VERSION=dev
ENV SIXWAYS_IMAGE_VERSION=${IMAGE_VERSION}

RUN apk add --no-cache \
    procps \
    nginx \
    curl \
    && mkdir -p /var/run/sixways \
    && chown sandbox:sandbox /var/run/sixways

# Baked extensions for offline/air-gapped environments
RUN mkdir -p /opt/extensions
COPY devcontainer/extensions/ /opt/extensions/

COPY --chmod=755 devcontainer/entrypoint-devcontainer.sh /entrypoint-devcontainer.sh
COPY --chmod=755 devcontainer/ide-entrypoint.sh /ide-entrypoint.sh
COPY devcontainer/config/nginx-mtls.conf /etc/sixways/nginx-mtls.conf
COPY --chmod=755 common/setup-tls.sh /opt/sixways/setup-tls.sh

# TLS cert directory and nginx working directories (writable by sandbox user)
RUN mkdir -p /etc/sixways/tls /var/lib/nginx/body /var/lib/nginx/proxy \
        /var/lib/nginx/fastcgi /var/lib/nginx/uwsgi /var/lib/nginx/scgi \
        /var/log/nginx /opt/sixways \
    && chown -R sandbox:sandbox /etc/sixways/tls /var/lib/nginx /var/log/nginx

# code-server port (used in IDE mode)
EXPOSE 8080

ENTRYPOINT ["/entrypoint-devcontainer.sh"]
