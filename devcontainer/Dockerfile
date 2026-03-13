ARG BASE_TAG=node
FROM ghcr.io/sixways-ai/sixways-sandbox:${BASE_TAG}

RUN apk add --no-cache \
    procps \
    && mkdir -p /var/run/endpoint \
    && chown sandbox:sandbox /var/run/endpoint

COPY --chmod=755 devcontainer/entrypoint-devcontainer.sh /entrypoint-devcontainer.sh

ENTRYPOINT ["/entrypoint-devcontainer.sh"]
