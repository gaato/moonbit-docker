# The official Node.js images are Debian based and carry the node binary the
# js backend shells out to; without it `moon run` and `moon test` fail on
# that target. The Debian release still determines the glibc the native
# backend links against.
ARG BASE_IMAGE=node:24-trixie-slim
FROM ${BASE_IMAGE}

# Exact upstream version such as "0.10.14+7d59c7ec9", "latest", or "nightly".
ARG MOONBIT_VERSION=latest

# World-writable so the image works under arbitrary UIDs
# (podman --userns=keep-id, devcontainers); moon writes its registry
# index and caches under MOON_HOME.
ENV MOON_HOME=/opt/moon
ENV PATH="${MOON_HOME}/bin:${PATH}"

# gcc and libc development headers are for the native backend.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        bash ca-certificates curl git gcc libc6-dev tar gzip; \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    curl -fsSL https://cli.moonbitlang.com/install/unix.sh \
        | MOONBIT_INSTALL_VERSION="${MOONBIT_VERSION}" bash; \
    # Verify the installed binaries against the upstream checksum list.
    version="$(printf '%s' "${MOONBIT_VERSION}" | sed 's/+/%2B/g')"; \
    curl -fsSL "https://cli.moonbitlang.com/binaries/${version}/moonbit-linux-$(uname -m).sha256" \
        | (cd "${MOON_HOME}/bin" && sha256sum -c --quiet -); \
    chmod -R a+rwX "${MOON_HOME}"; \
    moon version --all

# The base image wraps every command in a script that prepends `node` when
# the first argument starts with a dash, which would swallow `moon --help`.
ENTRYPOINT []
WORKDIR /work
CMD ["bash"]
