FROM python:3.14-slim

ARG BORG_VERSION=1.4.5

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      openssh-client \
      ca-certificates \
      fuse3 \
      build-essential \
      pkg-config \
      libssl-dev \
      libacl1-dev \
      liblz4-dev \
      libzstd-dev \
      libfuse3-dev \
 && pip install --no-cache-dir "borgbackup[pyfuse3]==${BORG_VERSION}" \
 && apt-get purge -y \
      build-essential \
      pkg-config \
      libssl-dev \
      libacl1-dev \
      liblz4-dev \
      libzstd-dev \
      libfuse3-dev \
 && apt-get autoremove -y \
 && rm -rf /var/lib/apt/lists/* \
 && borg --version

ENTRYPOINT ["borg"]