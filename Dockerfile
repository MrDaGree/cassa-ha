FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive

# Ansible + tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    ansible-core rsync python3 \
    util-linux kpartx e2fsprogs dosfstools parted \
    gzip ca-certificates curl gnupg \
 && rm -rf /var/lib/apt/lists/*

# chroot connection plugin
RUN ansible-galaxy collection install community.general

WORKDIR /ansible
COPY playbook.yaml .
COPY roles/ .

COPY entrypoint.sh /usr/local/bin/entrypoint
RUN chmod +x /usr/local/bin/entrypoint

ENTRYPOINT ["/usr/local/bin/entrypoint"]
