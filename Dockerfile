ARG BASE_IMAGE=debian:trixie-slim
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
    if command -v apt-get >/dev/null 2>&1; then \
        apt-get update; \
        apt-get install -y --no-install-recommends \
            bash ca-certificates curl git gcc libc6-dev tar gzip; \
        rm -rf /var/lib/apt/lists/*; \
    elif command -v zypper >/dev/null 2>&1; then \
        zypper --non-interactive refresh; \
        zypper --non-interactive install --no-recommends \
            bash ca-certificates curl git gcc glibc-devel tar gzip; \
        zypper --non-interactive clean --all; \
    elif command -v microdnf >/dev/null 2>&1; then \
        microdnf --assumeyes --setopt=install_weak_deps=0 install \
            bash ca-certificates curl-minimal git-core gcc glibc-devel tar gzip; \
        microdnf clean all; \
    else \
        echo 'Unsupported base image: apt-get, zypper or microdnf is required' >&2; \
        exit 1; \
    fi

RUN set -eux; \
    curl -fsSL https://cli.moonbitlang.com/install/unix.sh \
        | MOONBIT_INSTALL_VERSION="${MOONBIT_VERSION}" bash; \
    # Verify the installed binaries against the upstream checksum list.
    version="$(printf '%s' "${MOONBIT_VERSION}" | sed 's/+/%2B/g')"; \
    curl -fsSL "https://cli.moonbitlang.com/binaries/${version}/moonbit-linux-$(uname -m).sha256" \
        | (cd "${MOON_HOME}/bin" && sha256sum -c --quiet -); \
    chmod -R a+rwX "${MOON_HOME}"; \
    moon version --all

WORKDIR /work
CMD ["bash"]
