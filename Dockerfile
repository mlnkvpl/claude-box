FROM node:20-slim

# Install system utilities commonly needed by agent tools.
# jq/ripgrep/shellcheck/python3+python3-yaml: diagnostic/verification tools
# missing this session, all low-cost, no privilege/daemon implications.
# libnss3-tools: mkcert needs it to cover Firefox's own trust store too.
# gnupg: needed for the PHP apt repo signing key below.
RUN apt-get update && apt-get install -y --no-install-recommends \
        git curl ca-certificates procps \
        jq ripgrep shellcheck python3 python3-yaml libnss3-tools gnupg \
    && rm -rf /var/lib/apt/lists/*

# PHP 8.3 CLI + Composer — matches ululua/docker/api/Dockerfile.fpm's runtime
# version, so `php -l`, `composer validate`, etc. run against the same PHP
# this project actually deploys on, not whatever Debian's default happens to
# ship. Sury's repo is the standard way to get a specific modern PHP version
# on Debian; using /etc/os-release instead of lsb_release since slim images
# don't include lsb-release by default.
RUN curl -sSL https://packages.sury.org/php/apt.gpg -o /etc/apt/trusted.gpg.d/php.gpg \
    && . /etc/os-release \
    && echo "deb https://packages.sury.org/php/ ${VERSION_CODENAME} main" > /etc/apt/sources.list.d/php.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        php8.3-cli php8.3-mbstring php8.3-xml php8.3-curl php8.3-sqlite3 php8.3-pgsql \
    && rm -rf /var/lib/apt/lists/* \
    && curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

# mkcert — needed to actually exercise ../traefik's local TLS setup
# (S-0002_T-0003) instead of just reading the script and trusting it.
RUN curl -sSL "https://dl.filippo.io/mkcert/latest?for=linux/amd64" -o /usr/local/bin/mkcert \
    && chmod +x /usr/local/bin/mkcert

# --- Docker CLI (client only — Docker-outside-of-Docker) ---
# No daemon runs in this container. `docker`/`docker compose` here talk to
# docker-socket-proxy (see docker-compose.yml) over DOCKER_HOST, not to a raw
# mounted socket and not to a nested dockerd. The proxy holds the real
# /var/run/docker.sock and exposes only a scoped subset of the Docker API
# (containers/images/networks/volumes/build/exec, read+write; swarm/secrets/
# plugins/system left at its default-deny) — see docker-compose.yml for the
# exact grants. This still ultimately talks to the *same* host daemon as
# your own `docker`/`docker compose` on the host — same images, same
# containers, same everything, just filtered through the proxy.
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && . /etc/os-release \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# Install Claude Code and the official Chrome DevTools MCP server globally
RUN npm install -g @anthropic-ai/claude-code chrome-devtools-mcp

# Fix: the auto-updater runs as the `node` user at runtime but this global
# install happens as root at build time, so self-update fails with
# "no_permissions" (confirmed via ~/.claude/.last-update-result.json in a
# running session). Hand the install tree to `node` so it can update itself.
RUN chown -R node:node /usr/local/lib/node_modules /usr/local/bin

# Fallback only — docker-compose.yml's `working_dir:` overrides this at
# runtime to the host-mirrored path (see that file for why).
WORKDIR /workspace

ENTRYPOINT ["claude"]
