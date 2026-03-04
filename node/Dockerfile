ARG BASE_TAG=latest
FROM ghcr.io/sixways-ai/sixways-sandbox:${BASE_TAG}

ENV NPM_CONFIG_PREFIX=/home/sandbox/.npm-global
ENV PATH="/home/sandbox/.npm-global/bin:${PATH}"

RUN apk add --no-cache \
    nodejs-22 \
    npm \
    && mkdir -p /home/sandbox/.npm-global \
    && chown sandbox:sandbox /home/sandbox/.npm-global \
    && echo 'export PATH="/home/sandbox/.npm-global/bin:$PATH"' >> /home/sandbox/.bash_profile \
    && chown sandbox:sandbox /home/sandbox/.bash_profile
