# syntax=docker/dockerfile:1

# Home Assistant add-on wrapper around the official Sure image.
#
# Upstream publishes a multi-arch image (linux/amd64, linux/arm64) that already
# contains the built Rails app. This file adds PostgreSQL 16 and Redis so the
# add-on is self-contained, plus a startup script that translates
# /data/options.json into environment variables.
#
# Build locally with:
#   docker build -f Dockerfile .

ARG SURE_VERSION=0.7.6
FROM ghcr.io/we-promise/sure:${SURE_VERSION}

# The upstream image drops to uid 1000, but run.sh needs root to prepare /data.
# It drops privileges again for every long-running process.
USER root

# PostgreSQL comes from the PGDG repository pinned to one major version, so a
# Debian base bump can never change the major and orphan the data directory.
# Redis comes from Debian. No cluster is created: run.sh runs initdb on /data.
# policy-rc.d stops the packages from trying to start services during the build.
ARG PG_MAJOR=16
ENV PATH="/usr/lib/postgresql/${PG_MAJOR}/bin:${PATH}" PG_MAJOR="${PG_MAJOR}"
RUN set -eux; \
    . /etc/os-release; \
    mkdir -p /etc/postgresql-common /usr/share/postgresql-common/pgdg; \
    printf 'create_main_cluster = false\n' > /etc/postgresql-common/createcluster.conf; \
    printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d; chmod +x /usr/sbin/policy-rc.d; \
    curl -fsSL -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc; \
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main" > /etc/apt/sources.list.d/pgdg.list; \
    apt-get update -qq; \
    DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
        -o Dpkg::Options::=--force-confold "postgresql-${PG_MAJOR}" redis-server; \
    rm -f /usr/sbin/policy-rc.d; \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# run.sh depends on these from the upstream image and the packages above.
# Assert them at build time so a layout change fails CI instead of users' add-ons.
RUN test -x /rails/bin/docker-entrypoint && test -d /rails/storage \
    && command -v ruby setpriv redis-server postgres initdb pg_dump psql pg_isready >/dev/null

# Active Storage writes uploads (statements, logos, imports) to /rails/storage.
# Point it at the add-on's persistent volume so they survive a reinstall.
RUN rm -rf /rails/storage && ln -s /data/storage /rails/storage

COPY run.sh /usr/local/bin/run.sh
RUN chmod +x /usr/local/bin/run.sh

ENTRYPOINT ["/usr/local/bin/run.sh"]

# Deliberately not "./bin/rails server": that exact form makes the upstream
# entrypoint run db:prepare, which run.sh already does once for both processes.
CMD ["bundle", "exec", "rails", "server"]
