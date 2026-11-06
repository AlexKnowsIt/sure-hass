# syntax=docker/dockerfile:1

# Home Assistant add-on wrapper around the official Sure image.
#
# Upstream publishes a multi-arch image (linux/amd64, linux/arm64) that already
# contains the built Rails app, so this file only adds what Home Assistant needs:
# a startup script that translates /data/options.json into environment variables.
#
# Build locally with:
#   docker buildx build --platform linux/arm64 -f Dockerfile .

ARG SURE_VERSION=0.7.6
FROM ghcr.io/we-promise/sure:${SURE_VERSION}

# The upstream image drops to uid 1000, but Home Assistant mounts /data as root.
USER root

# jq parses the add-on options; the upstream image does not ship it.
RUN apt-get update -qq \
    && apt-get install --no-install-recommends -y jq \
    && rm -rf /var/lib/apt/lists /var/cache/apt/archives

# run.sh depends on both of these paths from the upstream image. Assert them at
# build time so an upstream layout change fails CI instead of users' add-ons.
RUN test -x /rails/bin/docker-entrypoint && test -d /rails/storage

# Active Storage writes uploads (statements, logos, imports) to /rails/storage.
# Point it at the add-on's persistent volume so they survive a reinstall.
RUN rm -rf /rails/storage && ln -s /data/storage /rails/storage

COPY run.sh /usr/local/bin/run.sh
RUN chmod +x /usr/local/bin/run.sh

ENTRYPOINT ["/usr/local/bin/run.sh"]

# Deliberately not "./bin/rails server": that exact form makes the upstream
# entrypoint run db:prepare, which run.sh already does once for both processes.
CMD ["bundle", "exec", "rails", "server"]
