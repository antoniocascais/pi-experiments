# pi-experiments — container image for running the `pi` coding agent over a
# checked-out codebase.
#
# The agent works on a git checkout at /state/work, its pi config lives at
# /state/pi-home/agent and its durable note ledger at /state/pi-notes -- all
# three on the state volume, all three outside each other. Nothing here is
# specific to any one repository.
#
# Base images are pinned by DIGEST, never a floating tag. To bump one:
#   docker pull <image>:<tag>
#   docker image inspect <image>:<tag> --format '{{index .RepoDigests 0}}'
# and paste the result into the matching ARG below. `make build` will not guess.
#
# Requires BuildKit (DOCKER_BUILDKIT=1, which `make build` always sets).

ARG NODE_IMAGE=node:22-bookworm-slim@sha256:83f487e0a63425e5b4d146fb5e5be574bcbe1b7b843d3ebafdd95eaf7767a7e5
ARG UV_IMAGE=ghcr.io/astral-sh/uv:python3.13-bookworm-slim@sha256:531f855bda2c73cd6ef67d56b733b357cea384185b3022bd09f05e002cd144ca
ARG GO_IMAGE=golang:1.27.1-bookworm@sha256:69a7b9788769bec032d238959b61854e9ae87f57be9029ec04e9885fabf99195
ARG GOLANGCI_LINT_IMAGE=golangci/golangci-lint:v2.14.0@sha256:ad862ba6b3798cbe0fd9fd7408d498fd74fbd2623a92406b2fd3898faf0bf98f

# Pinned exactly; `latest` in an image build is a reproducibility hole.
ARG PI_VERSION=0.85.1
# Orchestration extension. Zero runtime dependencies, MIT, no install scripts;
# see BOM.md for the source audit.
ARG CREW_VERSION=1.0.34
ARG PYTHON_VERSION=3.13.12
# Override to match the uid that owns a bind-mounted host workspace, otherwise
# the agent cannot write to its own worktree.
ARG AGENT_UID=1000
ARG AGENT_GID=1000
# Bare image by default -- see BOM.md "Optional toolchains".
ARG WITH_GO=0
ARG WITH_PYTHON=0

FROM ${UV_IMAGE} AS uv
FROM ${GO_IMAGE} AS go-toolchain
FROM ${GOLANGCI_LINT_IMAGE} AS golangci-lint

FROM ${NODE_IMAGE} AS base

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ENV DEBIAN_FRONTEND=noninteractive

# Patch the base image, then add only what an agent genuinely needs to read,
# search, edit, test and commit code. No compiler toolchain by default -- see
# the optional WITH_GO/WITH_PYTHON stages below. pi's find tool wants `fd`;
# Debian names it `fdfind`.
RUN apt-get update \
 && apt-get upgrade -y \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      fd-find \
      git \
      jq \
      less \
      make \
      ripgrep \
      tini \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* \
 && ln -s /usr/bin/fdfind /usr/local/bin/fd

# ---------------------------------------------------------------------------
# Optional Python toolchain (WITH_PYTHON=1). Off by default: pi itself needs
# only node, and a non-Python target codebase shouldn't carry uv/python's CVE
# surface for nothing.
FROM base AS python-0
FROM base AS python-1
ARG PYTHON_VERSION
COPY --from=uv /usr/local/bin/uv /usr/local/bin/uvx /usr/local/bin/
# Interpreter lives outside /state so a wiped state volume cannot strand the
# image, and outside $HOME so a read-only rootfs is still enough to run it.
ENV UV_PYTHON_INSTALL_DIR=/opt/uv/python
# uv's own shims land in root's ~/.local/bin, off the agent's PATH.
RUN uv python install "${PYTHON_VERSION}" \
 && chmod -R a+rX /opt/uv \
 && ln -s "$(uv python find "${PYTHON_VERSION}")" /usr/local/bin/python3 \
 && ln -s python3 /usr/local/bin/python
FROM python-${WITH_PYTHON} AS with-python

# ---------------------------------------------------------------------------
# Optional Go toolchain (WITH_GO=1). Same reasoning; off by default.
FROM with-python AS go-0
FROM with-python AS go-1
COPY --from=go-toolchain /usr/local/go /usr/local/go
COPY --from=golangci-lint /usr/bin/golangci-lint /usr/local/bin/golangci-lint
ENV PATH=/usr/local/go/bin:/state/cache/go/bin:$PATH \
    GOTOOLCHAIN=local \
    GOPATH=/state/cache/go \
    GOCACHE=/state/cache/go-build
FROM go-${WITH_GO} AS with-toolchains

FROM with-toolchains AS final
ARG PI_VERSION
ARG CREW_VERSION
ARG AGENT_UID
ARG AGENT_GID

# --ignore-scripts: pi ships a prebuilt bundle (bin -> dist/bundle/cli.js), so
# no lifecycle hook is needed, and disabling them removes arbitrary install-time
# code execution from its transitive packages.
RUN npm install -g --ignore-scripts "@earendil-works/pi-coding-agent@${PI_VERSION}" \
 && npm cache clean --force \
 && rm -rf /root/.npm

# ---------------------------------------------------------------------------
# Bake the pi config home while npm still exists.
#
# `pi install` shells out to npm and does NOT pass --ignore-scripts, so
# npm_config_ignore_scripts is forced through the environment instead. It
# installs into $PI_CODING_AGENT_DIR/npm, which at run time lives on the state
# volume -- hence the build-time home at /opt/pi-home, which the entrypoint
# seeds across on first run.
#
# pi only re-invokes npm when the installed path is missing or version-
# mismatched, so a correctly seeded install is never re-resolved -- which is
# what makes deleting npm below safe.
ENV PI_BUILD_HOME=/opt/pi-home
RUN npm_config_ignore_scripts=true \
    PI_CODING_AGENT_DIR="${PI_BUILD_HOME}/agent" \
    PI_SKIP_VERSION_CHECK=1 \
    PI_TELEMETRY=0 \
    pi install "npm:@melihmucuk/pi-crew@${CREW_VERSION}" \
 && test -d "${PI_BUILD_HOME}/agent/npm/node_modules/@melihmucuk/pi-crew" \
 && npm cache clean --force \
 && rm -rf /root/.npm

# Our own config lands after `pi install` so it wins over the settings.json pi wrote.
COPY pi-home/ ${PI_BUILD_HOME}/agent/
# Notes skeleton is data, not config, and must never be refreshed over a populated ledger.
COPY notes-skel/ /opt/pi-notes-skel/
COPY BOM.md /opt/pi-notes-skel/BOM.md
RUN chmod -R a+rX ${PI_BUILD_HOME} /opt/pi-notes-skel

# Remove npm once pi is installed. pi's own surface is a prebuilt bundle and
# doesn't need it; npm vendors the image's entire fixable-CVE surface (tar,
# pacote, sigstore, brace-expansion, ...) with no release that clears them.
# Nothing below this line may invoke a package manager.
RUN rm -rf /usr/local/lib/node_modules/npm \
           /usr/local/lib/node_modules/corepack \
           /usr/local/bin/npm \
           /usr/local/bin/npx \
           /usr/local/bin/corepack \
           /opt/yarn-v* \
           /usr/local/bin/yarn \
           /usr/local/bin/yarnpkg

# Reuse an existing group at AGENT_GID (e.g. the base image's own `node` group,
# or macOS's default gid 20) instead of failing groupadd on a collision.
RUN userdel -rf node 2>/dev/null || true; \
    if getent group "${AGENT_GID}" >/dev/null 2>&1; then \
      useradd -u "${AGENT_UID}" -g "${AGENT_GID}" -M -d /state/home -s /bin/bash agent; \
    else \
      groupadd -g "${AGENT_GID}" agent \
      && useradd -u "${AGENT_UID}" -g "${AGENT_GID}" -M -d /state/home -s /bin/bash agent; \
    fi \
 && mkdir -p /state/work \
 && chown -R "${AGENT_UID}:${AGENT_GID}" /state

COPY --chmod=0755 entrypoint.sh /usr/local/bin/pi-experiments-entrypoint

# Everything mutable is funnelled onto the state volume: pi's own config and
# session data, git identity, shell history, and every package cache. The root
# filesystem is then disposable and can be mounted read-only.
ENV HOME=/state/home \
    XDG_CONFIG_HOME=/state/home/.config \
    XDG_DATA_HOME=/state/home/.local/share \
    XDG_STATE_HOME=/state/home/.local/state \
    XDG_CACHE_HOME=/state/cache \
    UV_CACHE_DIR=/state/cache/uv \
    NPM_CONFIG_CACHE=/state/cache/npm \
    GIT_CONFIG_GLOBAL=/state/home/.gitconfig \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# PI_OFFLINE kills pi's own startup network calls (version/update checks,
# install telemetry) so it only talks to the model gateway. It is NOT egress
# confinement: container traffic bypasses the host firewall's OUTPUT chain
# (it's FORWARDed). Use `make up NETWORK=none`, or a firewalled docker network,
# if that matters. See README "Egress".
ENV PI_CODING_AGENT_DIR=/state/pi-home/agent \
    NOTES_ROOT=/state/pi-notes \
    PI_OFFLINE=1 \
    PI_SKIP_VERSION_CHECK=1 \
    PI_TELEMETRY=0

VOLUME ["/state"]
# /state/work is created above, already owned by the agent. Docker seeds a
# fresh named volume from the image's /state, so a root-owned directory here
# becomes a root-owned directory on the volume the agent then cannot write to.
WORKDIR /state/work
USER agent

# tini reaps the children pi spawns and forwards signals, so `docker stop` is a
# clean shutdown rather than a 10-second SIGKILL wait.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/pi-experiments-entrypoint"]
CMD ["pi"]
