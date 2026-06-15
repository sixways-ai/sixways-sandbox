# BASE_TAG selects the parent tag on GHCR (default path: .github/workflows/
# docker.yml passes BASE_TAG=base). BASE_IMAGE is the fully-qualified parent
# reference; it defaults to the GHCR ref built from BASE_TAG so the existing
# GHCR workflow is unchanged, but a registry-agnostic build (the signed
# Forgejo workflow) can override it to base off any registry host.
ARG BASE_TAG=latest
ARG BASE_IMAGE=ghcr.io/sixways-ai/sixways-sandbox:${BASE_TAG}
FROM ${BASE_IMAGE}

ENV NPM_CONFIG_PREFIX=/home/sandbox/.npm-global
ENV PATH="/home/sandbox/.npm-global/bin:${PATH}"

RUN apk add --no-cache \
    nodejs-22 \
    npm \
    # Reinstall npm from npmjs into /usr so its bundled deps (notably node-gyp,
    # which the apk-packaged npm strips) are present. Without this, any
    # `npm install -g <pkg>` whose dep tree includes native code fails with
    # "Cannot find module 'node-gyp/bin/node-gyp.js'".
    && HOME=/root npm install -g --prefix=/usr --cache /root/.npm npm@latest \
    # Drop the legacy apk-shipped builtin npmrc — its `python` and
    # `globalignorefile` keys aren't recognised by modern npm and produce
    # "Unknown builtin config" warnings on every command.
    && rm -f /usr/lib/node_modules/npm/npmrc \
    && rm -rf /home/sandbox/.npm /home/sandbox/.npm-global \
    && mkdir -p /home/sandbox/.npm-global \
    && chown sandbox:sandbox /home/sandbox/.npm-global \
    && echo 'export PATH="/home/sandbox/.npm-global/bin:$PATH"' >> /home/sandbox/.bash_profile \
    && chown sandbox:sandbox /home/sandbox/.bash_profile
