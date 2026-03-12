ARG BASE_TAG=node
FROM ghcr.io/sixways-ai/sixways-sandbox:${BASE_TAG}

RUN apk add --no-cache \
    tar \
    gzip \
    procps \
    libstdc++ \
    && mkdir -p /var/run/nforcer \
    && chown sandbox:sandbox /var/run/nforcer

COPY --chmod=755 entrypoint-devcontainer.sh /entrypoint-devcontainer.sh

ENTRYPOINT ["/entrypoint-devcontainer.sh"]
