ARG BASE_TAG=latest
FROM ghcr.io/sixways-ai/sixways-sandbox:${BASE_TAG}

ARG PYTHON_VERSION=3.12

ENV PATH="/home/sandbox/.local/bin:${PATH}"

RUN apk add --no-cache \
    python-${PYTHON_VERSION} \
    py${PYTHON_VERSION}-pip \
    && mkdir -p /home/sandbox/.local \
    && chown sandbox:sandbox /home/sandbox/.local \
    && echo 'export PATH="/home/sandbox/.local/bin:$PATH"' >> /home/sandbox/.bash_profile \
    && chown sandbox:sandbox /home/sandbox/.bash_profile
