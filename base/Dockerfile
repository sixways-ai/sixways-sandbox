FROM cgr.dev/chainguard/wolfi-base:latest@sha256:f4cbf50ca3225eb55c2b9b17286cd06c7d030f801aa1275c5d90638dd6df5fe9

RUN apk add --no-cache \
    openssh-server \
    openssh-client \
    git \
    bash \
    ca-certificates \
    shadow \
    && useradd -m -s /bin/bash -u 1000 sandbox \
    && usermod -p '*' sandbox \
    && apk del shadow \
    && mkdir -p /var/run/sshd /etc/ssh /var/empty \
    && mkdir -p /home/sandbox/.ssh \
    && chmod 700 /home/sandbox/.ssh \
    && chown sandbox:sandbox /home/sandbox/.ssh \
    && mkdir -p /workspace \
    && chown sandbox:sandbox /workspace \
    && rm -f /usr/bin/sudo /usr/bin/su \
    && rm -f /etc/ssh/ssh_host_*

COPY sshd_config /etc/ssh/sshd_config
COPY --chmod=755 entrypoint.sh /entrypoint.sh

EXPOSE 22
WORKDIR /workspace
ENTRYPOINT ["/entrypoint.sh"]
