# moonbit-docker

Unofficial container images of the [MoonBit](https://www.moonbitlang.com/)
toolchain, rebuilt automatically whenever upstream publishes a new release.

This project is not affiliated with the MoonBit team. The images contain the
upstream binaries as installed by the official install script; see
[License](#license).

```sh
podman run --rm -it -v "$PWD:/work:Z" ghcr.io/gaato/moonbit moon test
```

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
glibc 2.41), so the runtime image needs the same glibc or newer. Build output
goes to `_build/`, not `target/` as older articles say.

## Tags

| Tag | Meaning |
|---|---|
| `latest` | Current upstream release |
| `nightly` | Upstream nightly, rebuilt daily |
| `0.10.14` | That release (`+` is not valid in a tag, so the build hash is dropped) |
| `0.10.14-7d59c7ec9` | Same, with the upstream build hash (`0.10.14+7d59c7ec9`) |

Release version tags are built once and never rebuilt, so they do not pick up base
image updates. Images are published for `linux/amd64` and `linux/arm64`.
[`versions.txt`](versions.txt) lists every release version that has been built;
versions released before this repository existed are not backfilled.

## What is inside

- `debian:trixie-slim` (glibc 2.41) with `git`, `curl`, and `gcc`/`libc6-dev` for the native backend
- MoonBit in `/opt/moon` (`MOON_HOME`), checked against upstream's SHA-256 list
  at build time and writable by any UID, so `--user` and
  `--userns=keep-id` work

## How it works

A daily workflow reads <https://cli.moonbitlang.com/version.json>. If the
version is not in `versions.txt`, it builds both architectures on native
runners, publishes the manifest list, and appends the version to
`versions.txt`.

A separate daily workflow rebuilds `nightly` without the build cache. Both
architectures must pass the same smoke tests before the `nightly` tag is
updated. Nightly builds do not change `latest` or `versions.txt`; the nightly
workflow can also be run manually.

```fish
podman run --rm -it -v "$PWD:/work:Z" ghcr.io/gaato/moonbit:nightly moon test
```

To build a specific version by hand, run the workflow with the exact upstream
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
