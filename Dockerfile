ARG BASE_IMAGE=debian:trixie-slim
FROM ${BASE_IMAGE}

# Exact upstream version such as "0.10.14+7d59c7ec9", "latest", or "nightly".
ARG MOONBIT_VERSION=latest

# World-writable so the image works under arbitrary UIDs
# (podman --userns=keep-id, devcontainers); moon writes its registry
# index and caches under MOON_HOME.
ENV MOON_HOME=/opt/moon
ENV PATH="${MOON_HOME}/bin:${PATH}"

# gcc/libc6-dev are for the native backend.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash ca-certificates curl git gcc libc6-dev \
    && rm -rf /var/lib/apt/lists/*

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
