# moonbit-docker

[![ghcr.io](https://img.shields.io/badge/ghcr.io-gaato%2Fmoonbit-blue?logo=docker&logoColor=white)](https://github.com/gaato/moonbit-docker/pkgs/container/moonbit)
[![Build](https://github.com/gaato/moonbit-docker/actions/workflows/build.yml/badge.svg)](https://github.com/gaato/moonbit-docker/actions/workflows/build.yml)
[![Build nightly](https://github.com/gaato/moonbit-docker/actions/workflows/nightly.yml/badge.svg)](https://github.com/gaato/moonbit-docker/actions/workflows/nightly.yml)
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

Use `:nightly` to try the nightly toolchain, or a version tag such as `:0.10`
to stay on a release series.

### Multi-stage builds

```dockerfile
FROM ghcr.io/gaato/moonbit:0.10.14 AS build
COPY . .
RUN moon build --target native --release

FROM gcr.io/distroless/base-debian13
COPY --from=build /work/_build/native/release/build/cmd/main/main.exe /app
ENTRYPOINT ["/app"]
```

Adjust the executable path to match your project. Choose a builder base
compatible with your runtime: native binaries need a compatible glibc and
any other shared libraries they link against. For example, use a
`-bookworm` builder for a Debian 12 runtime.

### GitHub Actions

```yaml
jobs:
  test:
    runs-on: ubuntu-24.04
    container: ghcr.io/gaato/moonbit:0.10
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - run: moon test
```

## Bases

Tags without a suffix use Debian trixie and point to the same images as
`-trixie` tags. Use `-bookworm` to choose Debian 12, for example
`0.10-bookworm`.

| Tag suffix | Base image |
|---|---|
| none or `-trixie` | `node:24-trixie-slim` |
| `-bookworm` | `node:24-bookworm-slim` |

The bases are the Debian variants of the official Node.js images, so the
Debian release still determines the glibc the native backend links against.
Node is there because the js backend shells out to it: `moon run` and
`moon test` need it on that target.

The images contain the upstream MoonBit toolchain in `/opt/moon`, plus `node`,
`npm`, `git`, `curl`, `gcc`, and libc development headers. The toolchain
directory is writable by any UID, allowing use with `--user` or
`--userns=keep-id`.

The Node major is fixed at build time and is not updated within a published
release tag, the same as the rest of the base.

## Tags

| Tag | Meaning |
|---|---|
| `latest` | Latest published upstream release for the base |
| `nightly` | Upstream nightly, rebuilt daily |
| `nightly-YYYYMMDD` | First successful nightly publication on that UTC date |
| `0.10` | Latest published patch release in the `0.10.x` series |
| `0.10.14` | Release version without the build hash |
| `0.10.14-7d59c7ec9` | Exact upstream version `0.10.14+7d59c7ec9` |

Minor tags stay within their series: `0.10` does not move to `0.11`.
Dated nightly tags are preserved after publication. Use an image digest to
pin an exact image.

## Updates

Each base is published once both `linux/amd64` and `linux/arm64` pass smoke
tests. Bases publish independently, so a failed build can leave one base on
an older version. See [`versions.json`](versions.json) for published releases
by base.

Daily workflows check for new releases and rebuild nightly images. Release
images do not receive automatic base image updates. Older releases and dated
nightlies are not backfilled when a base is added.

## Maintenance

The Build workflow accepts an upstream `version` such as
`0.10.14+7d59c7ec9` and a `base` from [`bases.json`](bases.json), or `all`
(the default). Specifying a version forces a rebuild; leaving it empty
builds the current release for bases that have not published it yet.
The nightly workflow also accepts `base`.

Pull requests run the CI workflow, which builds every base for both
architectures from the current upstream release and runs the smoke test
without publishing.

Run the publication tests locally:

```fish
prove scripts/*.t
```

## License

The build scripts in this repository are under the
[Blue Oak Model License 1.0.0](LICENSE.md). That license does not cover
MoonBit itself. Upstream publishes the sources of
[moon](https://github.com/moonbitlang/moon/blob/main/LICENSE) and
[core](https://github.com/moonbitlang/core/blob/main/LICENSE) under
Apache-2.0, and of the
[compiler](https://github.com/moonbitlang/moonbit-compiler/blob/main/LICENSE.TXT)
under the MoonBit Public Source License.
