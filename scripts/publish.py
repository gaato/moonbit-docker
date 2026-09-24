#!/usr/bin/env python3
import json
import os
import re
import subprocess
import sys
from collections.abc import Callable, Iterable, Mapping, Sequence
from datetime import UTC, datetime
from typing import NotRequired, TypedDict, cast

VERSION_PATTERN = re.compile(
    r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\+([0-9a-f]+)"
)
SUFFIX_PATTERN = re.compile(r"(?:-[a-z0-9][a-z0-9.-]*)?")

type Version = tuple[int, int, int, str]
type History = dict[str, list[str]]


class Target(TypedDict):
    name: str


class Base(TypedDict):
    name: str
    image: str
    suffix: str
    architectures: list[str]
    aliases: NotRequired[list[str]]


class Fail(Exception):
    pass


def env(name: str) -> str:
    value = os.environ.get(name)
    if value is None:
        raise Fail(f"{name} is required")
    return value


def matches(pattern: str | re.Pattern[str], value: object) -> bool:
    return isinstance(value, str) and re.fullmatch(pattern, value) is not None


def run(*args: str) -> None:
    status = subprocess.run(args, check=False).returncode
    if status != 0:
        raise Fail(f"{args[0]} failed (status {status})")


def capture(*args: str) -> str:
    try:
        result = subprocess.run(args, stdout=subprocess.PIPE, text=True, check=False)
    except OSError as error:
        raise Fail(f"Cannot start {args[0]}: {error}") from error
    if result.returncode != 0:
        raise Fail(f"{args[0]} failed (status {result.returncode})")
    return result.stdout


def parse_version(version: object) -> Version:
    match = VERSION_PATTERN.fullmatch(version) if isinstance(version, str) else None
    if not match:
        raise Fail(f"Invalid release version: {version}")
    major, minor, patch, commit = match.groups()
    return int(major), int(minor), int(patch), commit


def read_json(path: str) -> object:
    try:
        with open(path) as file:
            return json.load(file)
    except OSError as error:
        raise Fail(f"Cannot read {path}: {error.strerror}") from error
    except ValueError as error:
        raise Fail(f"Invalid JSON in {path}: {error}") from error


def encode_json(value: object) -> str:
    # Matches JSON::PP canonical pretty output, the existing file format.
    return json.dumps(value, sort_keys=True, indent=3, separators=(",", " : ")) + "\n"


def write_json(path: str, value: object) -> None:
    with open(f"{path}.tmp", "w") as file:
        file.write(encode_json(value))
    os.replace(f"{path}.tmp", path)


def read_bases() -> list[Base]:
    bases = read_json("bases.json")
    if not isinstance(bases, list) or not bases:
        raise Fail("Expected a nonempty base list")
    names: set[str] = set()
    suffixes: set[str] = set()
    for base in bases:
        if not (
            isinstance(base, dict)
            and matches(r"[a-z0-9][a-z0-9.-]*", base.get("name"))
            and matches(r"[a-z0-9][a-z0-9.:/-]*", base.get("image"))
            and matches(SUFFIX_PATTERN, base.get("suffix"))
        ):
            raise Fail("Invalid base definition")
        if base["name"] in names:
            raise Fail("Duplicate base name")
        names.add(base["name"])
        if base.get("architectures") != ["amd64", "arm64"]:
            raise Fail("Invalid base architectures")
        if "os" in base or "runner" in base:
            raise Fail("Unsupported base platform")
        if "aliases" in base and not isinstance(base["aliases"], list):
            raise Fail("Expected alias array")
        for suffix in [base["suffix"], *base.get("aliases", [])]:
            if not matches(SUFFIX_PATTERN, suffix):
                raise Fail("Invalid tag suffix")
            if suffix in suffixes:
                raise Fail("Duplicate tag suffix")
            suffixes.add(suffix)
    return cast(list[Base], bases)


def read_versions(path: str) -> History:
    history = read_json(path)
    if not isinstance(history, dict):
        raise Fail("Expected base-keyed version history")
    for versions in history.values():
        if not isinstance(versions, list):
            raise Fail("Expected version array")
        for version in versions:
            parse_version(version)
    return cast(History, history)


def release_tags(version: str, latest: bool, history: Iterable[str]) -> list[str]:
    major, minor, patch, commit = parse_version(version)
    # Rebuilding an older patch must not move the minor tag backward.
    # Rebuilding the newest patch may refresh it with a new base image.
    newest = True
    for published in history:
        a, b, c, _ = parse_version(published)
        if a == major and b == minor and c > patch:
            newest = False
    tags = [f"{major}.{minor}.{patch}", f"{major}.{minor}.{patch}-{commit}"]
    if newest:
        tags.append(f"{major}.{minor}")
    if latest:
        tags.append("latest")
    return tags


def sources(image: str, directory: str, architectures: Iterable[str]) -> list[str]:
    result: list[str] = []
    for arch in architectures:
        try:
            with open(f"{directory}/{arch}.digest") as file:
                digest = file.read().removesuffix("\n")
        except OSError as error:
            raise Fail(f"Missing {arch} digest: {error.strerror}") from error
        if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
            raise Fail(f"Invalid {arch} digest")
        result.append(f"{image}@{digest}")
    if len(result) == 2 and result[0] == result[1]:
        raise Fail("Architecture digests must differ")
    return result


def registry_token(repository: str) -> str:
    response: object = json.loads(
        capture(
            "curl",
            "-fsS",
            "--get",
            "https://ghcr.io/token",
            "--data-urlencode",
            "service=ghcr.io",
            "--data-urlencode",
            f"scope=repository:{repository}:pull",
        )
    )
    token = response.get("token") if isinstance(response, dict) else None
    if not isinstance(token, str) or not token:
        raise Fail("Missing registry token")
    return token


def dated_tag_exists(repository: str, tag: str, token: str) -> bool:
    status = capture(
        "curl",
        "-sS",
        "--head",
        "--output",
        "/dev/null",
        "--write-out",
        "%{http_code}",
        "--header",
        f"Authorization: Bearer {token}",
        "--header",
        "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json",
        f"https://ghcr.io/v2/{repository}/manifests/{tag}",
    )
    if status == "200":
        return True
    if status == "404":
        return False
    raise Fail(f"Cannot check {tag}: HTTP {status}")


def tag_args(image: str, tags: Iterable[str]) -> list[str]:
    return [arg for tag in tags for arg in ("-t", f"{image}:{tag}")]


def publish(
    image: str,
    version: str,
    latest: bool,
    digest_dir: str,
    history: Mapping[str, Sequence[str]],
    base: Base,
) -> None:
    suffixes = [base["suffix"], *base.get("aliases", [])]
    image_sources = sources(
        image, f"{digest_dir}/{base['name']}", base["architectures"]
    )
    if version == "nightly":
        if not image.startswith("ghcr.io/"):
            raise Fail("Expected a ghcr.io image")
        repository = image.removeprefix("ghcr.io/")
        # Date each base at publication time; independent builds may span midnight.
        date = "nightly-" + datetime.now(UTC).strftime("%Y%m%d")
        dated = [f"{date}{suffix}" for suffix in suffixes]
        token = registry_token(repository)
        existing: list[str] = []
        missing: list[str] = []
        for tag in dated:
            if dated_tag_exists(repository, tag, token):
                existing.append(tag)
            else:
                missing.append(tag)
        tags = [f"nightly{suffix}" for suffix in suffixes]
        if existing:
            # A newly introduced alias or a partial publish must reuse the day's
            # original index, not today's rebuilt image. A single index source
            # is copied unchanged by imagetools create.
            if missing:
                run(
                    "docker",
                    "buildx",
                    "imagetools",
                    "create",
                    *tag_args(image, missing),
                    f"{image}:{existing[0]}",
                )
        else:
            tags += missing
        inspect = [*(f"nightly{suffix}" for suffix in suffixes), *dated]
    else:
        tags = [
            f"{tag}{suffix}"
            for tag in release_tags(version, latest, history.get(base["name"], []))
            for suffix in suffixes
        ]
        inspect = tags
    run(
        "docker",
        "buildx",
        "imagetools",
        "create",
        *tag_args(image, tags),
        *image_sources,
    )
    for tag in inspect:
        run("docker", "buildx", "imagetools", "inspect", f"{image}:{tag}")


def main() -> None:
    image = env("IMAGE")
    version = env("VERSION")
    name = env("BASE")
    digest_dir = env("DIGEST_DIR")
    base = next((base for base in read_bases() if base["name"] == name), None)
    if base is None:
        raise Fail(f"Unknown base: {name}")
    latest = os.environ.get("LATEST", "false") == "true"
    history: History = {}
    if version != "nightly":
        # Refresh history for reruns without giving publication jobs write access.
        run("git", "pull", "--ff-only")
        history = read_versions("versions.json")
    publish(image, version, latest, digest_dir, history, base)
    # This receipt is uploaded only after all publication checks succeed.
    if version != "nightly":
        receipt_dir = env("RECEIPT_DIR")
        os.makedirs(receipt_dir, exist_ok=True)
        write_json(f"{receipt_dir}/{name}.json", {"base": name, "version": version})


def cli(entry: Callable[[], None]) -> int:
    try:
        entry()
    except Fail as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(cli(main))
