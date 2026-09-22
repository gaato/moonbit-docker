# moonbit-docker

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
glibc 2.41), so the runtime image needs the same glibc or newer.

## Tags

| Tag | Meaning |
|---|---|
| `latest` | Current upstream release |
| `nightly` | Upstream nightly, rebuilt daily |
| `nightly-YYYYMMDD` | First successful nightly image published on that UTC date |
| `0.10.14` | Release version without the build hash |
| `0.10.14-7d59c7ec9` | Exact upstream version `0.10.14+7d59c7ec9` |

Dated nightly tags are preserved on subsequent runs that day. Use a dated
tag or an image digest to pin a nightly build.

Release images are built when a new upstream version is detected; they do
not receive automatic base image updates. [`versions.txt`](versions.txt)
lists published releases. Older releases are not backfilled.

## What is inside

- `debian:trixie-slim` (glibc 2.41) with `git`, `curl`, and `gcc`/`libc6-dev` for the native backend
- MoonBit in `/opt/moon` (`MOON_HOME`), checked against upstream's SHA-256 list
  at build time and writable by any UID, so `--user` and
  `--userns=keep-id` work

## Updates

Daily workflows check for new releases and rebuild nightly images. Both
architectures must pass smoke tests before tags are published.

To publish a specific release manually, run the Build workflow with its upstream
version string (`0.10.14+7d59c7ec9`). Upstream only keeps recent releases;
for older ones see [moonbit-binaries](https://github.com/chawyehsu/moonbit-binaries).

## License

The build scripts in this repository are under the
[Blue Oak Model License 1.0.0](LICENSE.md). That license does not cover
MoonBit itself. Upstream publishes the sources of
[moon](https://github.com/moonbitlang/moon/blob/main/LICENSE) and
[core](https://github.com/moonbitlang/core/blob/main/LICENSE) under
Apache-2.0, and of the
[compiler](https://github.com/moonbitlang/moonbit-compiler/blob/main/LICENSE.TXT)
under the MoonBit Public Source License.
