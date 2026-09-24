#!/usr/bin/env bash
# Smoke test: ./test.sh IMAGE
#
# Only exit codes are checked. The project comes from `moon new`, so the test
# does not break when upstream changes the template or the package format.
set -euo pipefail

image=${1:?usage: $0 IMAGE}
engine=${ENGINE:-$(command -v podman || command -v docker)}

# Arbitrary non-root UID: MOON_HOME must stay usable without owning it.
"$engine" run --rm --user 12345:12345 -e HOME=/tmp "$image" bash -euxc '
  cd /tmp
  moon new hello
  cd hello
  moon check
  moon test
  moon run cmd/main
  moon run --target native cmd/main
  moon build --target native --release
  moon build --target js --release
  # Running the js output spawns node, so this is what proves the base
  # image still supplies it. moon test --target js would not: the template
  # has no tests, so it exits before reaching node.
  moon run --target js cmd/main
  moon build --target wasm --release
'
