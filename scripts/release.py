#!/usr/bin/env python3
import json
import os
import sys
from collections.abc import Iterable, Mapping, Sequence

import publish as p
from publish import Base, Fail, History, Target


def select_bases(
    bases: Sequence[Base],
    history: Mapping[str, Sequence[str]],
    version: str,
    selector: str,
    force: bool,
) -> list[Base]:
    if selector != "all" and not any(base["name"] == selector for base in bases):
        raise Fail(f"Unknown base: {selector}")
    return [
        base
        for base in bases
        if (selector == "all" or base["name"] == selector)
        and (
            force
            or version == "nightly"
            or version not in history.get(base["name"], [])
        )
    ]


def upstream_version() -> str:
    response: object = json.loads(
        p.capture("curl", "-fsSL", "https://cli.moonbitlang.com/version.json")
    )
    items = response.get("items") if isinstance(response, dict) else None
    compiler = (
        next(
            (
                item
                for item in items
                if isinstance(item, dict) and item.get("name") == "moonc"
            ),
            None,
        )
        if isinstance(items, list)
        else None
    )
    version = compiler.get("version") if compiler is not None else None
    if not isinstance(version, str):
        raise Fail("Missing upstream compiler version")
    return version.removeprefix("v").split(" ", 1)[0]


def prepare() -> None:
    bases = p.read_bases()
    requested = os.environ.get("INPUT_VERSION", "")
    selector = os.environ.get("INPUT_BASE") or "all"
    version = "nightly"
    latest = False
    history: History = {}
    if os.environ.get("CHANNEL", "release") != "nightly":
        p.run("git", "pull", "--ff-only")
        history = p.read_versions("versions.json")
        upstream = upstream_version()
        p.parse_version(upstream)
        version = requested or upstream
        p.parse_version(version)
        latest = version == upstream
    # Automatic runs retry only the current release, never a backlog. An explicit
    # version forces selected bases to rebuild even when history records success.
    selected = select_bases(bases, history, version, selector, bool(requested))
    matrix = json.dumps({"include": selected}, sort_keys=True, separators=(",", ":"))
    with open(p.env("GITHUB_OUTPUT"), "a") as file:
        file.write(
            f"build={'true' if selected else 'false'}\n"
            f"version={version}\nlatest={'true' if latest else 'false'}\nmatrix={matrix}\n"
        )
    print("Selected bases:", ", ".join(base["name"] for base in selected))


def merge_receipts(
    history: History, directory: str, version: str, targets: Iterable[Target]
) -> bool:
    p.parse_version(version)
    allowed = {target["name"] for target in targets}
    published: list[str] = []
    if os.path.isdir(directory):
        for name in sorted(
            name for name in os.listdir(directory) if name.endswith(".json")
        ):
            receipt = p.read_json(f"{directory}/{name}")
            base = receipt.get("base") if isinstance(receipt, dict) else None
            if not (
                isinstance(receipt, dict)
                and isinstance(base, str)
                and base in allowed
                and receipt.get("version") == version
                and name == f"{base}.json"
            ):
                raise Fail(f"Invalid publication receipt: {name}")
            published.append(base)
    # Validate every receipt before touching the history.
    changed = False
    for base in published:
        versions = history.setdefault(base, [])
        if version in versions:
            continue
        versions.append(version)
        changed = True
    return changed


def read_targets(known: Iterable[str]) -> list[Target]:
    matrix: object = json.loads(p.env("TARGETS"))
    include = matrix.get("include") if isinstance(matrix, dict) else None
    if not isinstance(include, list):
        raise Fail("Invalid target matrix")
    names = set(known)
    targets: list[Target] = []
    for target in include:
        name = target.get("name") if isinstance(target, dict) else None
        if not isinstance(name, str) or name not in names:
            raise Fail("Unknown receipt target")
        targets.append({"name": name})
    return targets


def record() -> None:
    version = p.env("VERSION")
    directory = p.env("RECEIPT_DIR")
    targets = read_targets(base["name"] for base in p.read_bases())
    p.run("git", "pull", "--ff-only")
    history = p.read_versions("versions.json")
    if not merge_receipts(history, directory, version, targets):
        print("No new successful publications to record")
        return
    p.write_json("versions.json", history)
    p.run("git", "config", "user.name", "github-actions[bot]")
    p.run(
        "git",
        "config",
        "user.email",
        "41898282+github-actions[bot]@users.noreply.github.com",
    )
    p.run("git", "add", "versions.json")
    p.run("git", "commit", "-m", f"Record published bases for {version}")
    # Registry publication has already happened. If this push fails, the next
    # automatic run may rebuild bases whose success was not recorded.
    p.run("git", "push")


def release_main() -> None:
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command == "prepare":
        prepare()
    elif command == "record":
        record()
    else:
        raise Fail(f"usage: {sys.argv[0]} prepare|record")


if __name__ == "__main__":
    sys.exit(p.cli(release_main))
