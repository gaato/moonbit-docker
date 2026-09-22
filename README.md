# moonbit-docker

[![Build](https://github.com/gaato/moonbit-docker/actions/workflows/build.yml/badge.svg)](https://github.com/gaato/moonbit-docker/actions/workflows/build.yml)
[![Build nightly](https://github.com/gaato/moonbit-docker/actions/workflows/nightly.yml/badge.svg)](https://github.com/gaato/moonbit-docker/actions/workflows/nightly.yml)
[![ghcr.io](https://img.shields.io/badge/ghcr.io-gaato%2Fmoonbit-blue?logo=docker&logoColor=white)](https://github.com/gaato/moonbit-docker/pkgs/container/moonbit)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/gaato/moonbit-docker)
[![License](https://img.shields.io/github/license/gaato/moonbit-docker)](LICENSE.md)

Unofficial [MoonBit](https://www.moonbitlang.com/) toolchain images for
`linux/amd64` and `linux/arm64`, with release and nightly tags.

This project is not affiliated with the MoonBit team. The images contain the
upstream binaries as installed by the official install script; see
[License](#license).

## Usage

Run tests in the current directory:

```fish
podman run --rm -it -v "$PWD:/work:Z" ghcr.io/gaato/moonbit:latest moon test
```

Use `:nightly` instead of `:latest` to try the nightly toolchain.
Tags without a distribution suffix use Debian trixie. Append `-bookworm`
to any tag (for example, `latest-bookworm` or `nightly-bookworm`) to use
Debian bookworm instead, or `-bci16.0` for SUSE BCI 16.0. The Debian variants
use slim base images; the SUSE variant uses BCI Base.

## As a build stage

```dockerfile
FROM ghcr.io/gaato/moonbit:0.10.14 AS build
COPY . .
RUN moon build --target native --release

FROM gcr.io/distroless/base-debian13
COPY --from=build /work/_build/native/release/build/cmd/main/main.exe /app
ENTRYPOINT ["/app"]
```

Native binaries link dynamically against the builder's glibc (Debian 13,
glibc 2.41 by default), so the runtime image needs the same glibc or newer,
along with any other required shared libraries. Use a `-bookworm` builder
for Debian 12 runtimes (glibc 2.36).
Use a `-bci16.0` builder for SUSE BCI 16.0 runtimes (glibc 2.40).

## Tags

| Tag | Meaning |
|---|---|
| `latest` | Current upstream release |
| `nightly` | Upstream nightly, rebuilt daily |
| `nightly-YYYYMMDD` | First successful nightly image published on that UTC date |
| `0.10` | Latest published patch release in the `0.10.x` series |
| `0.10.14` | Release version without the build hash |
| `0.10.14-7d59c7ec9` | Exact upstream version `0.10.14+7d59c7ec9` |

New builds also provide `-bookworm` and `-bci16.0` variants of each tag,
such as `0.10-bookworm`, `0.10-bci16.0`, `0.10.14-7d59c7ec9-bci16.0`,
or `nightly-YYYYMMDD-bci16.0`. Minor tags stay within their series: `0.10`
does not move to `0.11`, and rebuilding an older patch does not move it
backward. Rebuilding the newest patch can update its minor tag.

Dated nightly tags are preserved on subsequent runs that day. Use a dated
tag or an image digest to pin a nightly build. Preservation is checked
separately for each distribution.

Release images are built when a new upstream version is detected; they do
not receive automatic base image updates. [`versions.txt`](versions.txt)
lists published releases. Older releases are not backfilled.
Existing dated nightlies are not backfilled with new distribution variants either.

## What is inside

- `debian:trixie-slim` (glibc 2.41) by default, `debian:bookworm-slim`
  (glibc 2.36) for `-bookworm` tags, or `registry.suse.com/bci/bci-base:16.0`
  (glibc 2.40) for `-bci16.0` tags
- `git`, `curl`, `gcc`, and libc development headers for the native backend
- MoonBit in `/opt/moon` (`MOON_HOME`), checked against upstream's SHA-256 list
  at build time and writable by any UID, so `--user` and
  `--userns=keep-id` work

## Updates

Daily workflows check for new releases and rebuild nightly images. All three
base images on both architectures must pass smoke tests before tags are
published.

To publish a specific release manually, run the Build workflow with its upstream
version string (`0.10.14+7d59c7ec9`). Upstream only keeps recent releases;
for older ones see [moonbit-binaries](https://github.com/chawyehsu/moonbit-binaries).

Publication logic lives in `scripts/publish.pl` and uses only standard Perl
modules plus the existing `curl`, `docker`, and `git` tools. Run its tests with
`prove scripts/publish.t`; the tests do not contact the registry or publish images.

## License

The build scripts in this repository are under the
[Blue Oak Model License 1.0.0](LICENSE.md). That license does not cover
MoonBit itself. Upstream publishes the sources of
[moon](https://github.com/moonbitlang/moon/blob/main/LICENSE) and
[core](https://github.com/moonbitlang/core/blob/main/LICENSE) under
Apache-2.0, and of the
[compiler](https://github.com/moonbitlang/moonbit-compiler/blob/main/LICENSE.TXT)
under the MoonBit Public Source License.
