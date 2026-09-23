# moonbit-docker

[![Build](https://github.com/gaato/moonbit-docker/actions/workflows/build.yml/badge.svg)](https://github.com/gaato/moonbit-docker/actions/workflows/build.yml)
[![Build nightly](https://github.com/gaato/moonbit-docker/actions/workflows/nightly.yml/badge.svg)](https://github.com/gaato/moonbit-docker/actions/workflows/nightly.yml)
[![ghcr.io](https://img.shields.io/badge/ghcr.io-gaato%2Fmoonbit-blue?logo=docker&logoColor=white)](https://github.com/gaato/moonbit-docker/pkgs/container/moonbit)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/gaato/moonbit-docker)
[![License](https://img.shields.io/github/license/gaato/moonbit-docker)](LICENSE.md)

Unofficial [MoonBit](https://www.moonbitlang.com/) toolchain images for
`linux/amd64`, `linux/arm64`, and Windows Server Core `windows/amd64`,
with release and nightly tags.

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
`-trixie` tags. Append a suffix to any tag to
choose another base, for example `0.10-bookworm` or
`0.10-windowsservercore-ltsc2025`.

| Tag suffix | Base image |
|---|---|
| none or `-trixie` | `debian:trixie-slim` |
| `-bookworm` | `debian:bookworm-slim` |
| `-windowsservercore-ltsc2022` | `mcr.microsoft.com/dotnet/framework/runtime:4.8-windowsservercore-ltsc2022` |
| `-windowsservercore-ltsc2025` | `mcr.microsoft.com/dotnet/framework/runtime:4.8.1-windowsservercore-ltsc2025` |

The Debian variants contain the upstream MoonBit toolchain in `/opt/moon`, plus
`git`, `curl`, `gcc`, and libc development headers. The toolchain directory
is writable by any UID, allowing use with `--user` or `--userns=keep-id`.

The Windows variants contain the upstream Windows toolchain in `C:\moon` and
Visual Studio Build Tools for native builds. They run on Windows hosts with
Windows containers enabled. Before a native build in a shell, initialize the
MSVC environment with `C:\BuildTools\Common7\Tools\VsDevCmd.bat -arch=amd64`.

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

Each Debian base is published once both `linux/amd64` and `linux/arm64` pass
smoke tests. Each Windows Server Core base is published after its
`windows/amd64` test passes. Bases publish independently, so a failed build
can leave one base on an older version. See [`versions.json`](versions.json)
for published releases by base. Existing tags for removed Linux bases remain
in the registry but are no longer updated.

Daily workflows check for new releases and rebuild nightly images. Release
images do not receive automatic base image updates. Older releases and dated
nightlies are not backfilled when a base is added.

## Maintenance

The Build workflow accepts an upstream `version` such as
`0.10.14+7d59c7ec9` and a `base` from [`bases.json`](bases.json), or `all`
(the default). Specifying a version forces a rebuild; leaving it empty
builds the current release for bases that have not published it yet.
The nightly workflow also accepts `base`.

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
