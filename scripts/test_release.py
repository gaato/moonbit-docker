import contextlib
import io
import json
import os
import re
import tempfile
import unittest
from collections.abc import Collection, Iterable
from pathlib import Path
from unittest import mock

import publish
import release
from publish import Fail

REPO = Path(__file__).resolve().parent.parent
with contextlib.chdir(REPO):
    BASES = publish.read_bases()
    STORED_HISTORY = publish.read_versions("versions.json")
IMAGE = "ghcr.io/test/moonbit"
VERSION = "0.10.10+bbb"


def tag_args(tags: Iterable[str]) -> list[str]:
    return publish.tag_args(IMAGE, tags)


class RepositoryTest(unittest.TestCase):
    def test_history_covers_configured_bases(self) -> None:
        self.assertEqual(sorted(STORED_HISTORY), sorted(base["name"] for base in BASES))


class ReleaseTagsTest(unittest.TestCase):
    def test_release_tags(self) -> None:
        cases: list[tuple[str, str, list[str], bool, list[str]]] = [
            ("new series", "0.10.9+aaa", [], False, ["0.10.9", "0.10.9-aaa", "0.10"]),
            (
                "numeric ordering",
                "0.10.10+bbb",
                ["0.10.9+aaa"],
                True,
                ["0.10.10", "0.10.10-bbb", "0.10", "latest"],
            ),
            (
                "older rebuild",
                "0.10.9+aaa",
                ["0.10.10+bbb"],
                False,
                ["0.10.9", "0.10.9-aaa"],
            ),
            (
                "same patch",
                "0.10.10+ccc",
                ["0.10.10+bbb"],
                False,
                ["0.10.10", "0.10.10-ccc", "0.10"],
            ),
            (
                "other series",
                "0.10.11+ccc",
                ["0.11.0+ddd", "0.100.99+eee"],
                False,
                ["0.10.11", "0.10.11-ccc", "0.10"],
            ),
        ]
        for name, version, history, latest, expected in cases:
            with self.subTest(name):
                self.assertEqual(
                    publish.release_tags(version, latest, history), expected
                )

    def test_invalid_release_rejected(self) -> None:
        with self.assertRaisesRegex(Fail, "Invalid release"):
            publish.release_tags("nightly", False, [])

    def test_missing_history_fails_closed(self) -> None:
        with self.assertRaisesRegex(Fail, "Cannot read"):
            publish.read_versions("/nonexistent/moonbit-versions.json")


class WorkspaceTest(unittest.TestCase):
    """Runs each test in a scratch directory holding bases, history, and digests."""

    def setUp(self) -> None:
        self.enterContext(
            contextlib.chdir(self.enterContext(tempfile.TemporaryDirectory()))
        )
        publish.write_json("bases.json", BASES)
        publish.write_json("versions.json", {})
        self.digests: dict[str, dict[str, str]] = {}
        serial = 0
        for base in BASES:
            os.makedirs(f"digests/{base['name']}")
            for arch in base["architectures"]:
                serial += 1
                digest = f"sha256:{serial:064x}"
                self.digests.setdefault(base["name"], {})[arch] = digest
                Path(f"digests/{base['name']}/{arch}.digest").write_text(f"{digest}\n")
        self.enterContext(contextlib.redirect_stdout(io.StringIO()))

    def record_commands(self) -> list[list[str]]:
        commands: list[list[str]] = []

        def fake(*args: str) -> None:
            commands.append(list(args))

        self.enterContext(mock.patch.object(publish, "run", fake))
        return commands

    def fake_registry(
        self, found: Collection[str] = (), status: str | None = None
    ) -> list[str]:
        """Answers dated tag lookups: 200 for suffixes in found, else 404."""
        dates: list[str] = []

        def capture(*args: str) -> str:
            if args[1] == "-fsS":
                return '{"token":"test-token"}'
            match = re.search(r"nightly-(\d{8})(.*)$", args[-1])
            assert match, args[-1]
            dates.append(match[1])
            return status or ("200" if match[2] in found else "404")

        self.enterContext(mock.patch.object(publish, "capture", capture))
        return dates

    def sources(self, name: str) -> list[str]:
        return [f"{IMAGE}@{self.digests[name][arch]}" for arch in ("amd64", "arm64")]


class PublishTest(WorkspaceTest):
    def test_release_tags_are_isolated_per_base(self) -> None:
        history = {"trixie": ["0.10.11+ccc"]}
        for base in BASES:
            with self.subTest(base["name"]):
                commands = self.record_commands()
                publish.publish(IMAGE, VERSION, False, "digests", history, base)
                tags = ["0.10.10", "0.10.10-bbb"]
                if base["name"] != "trixie":
                    tags.append("0.10")
                suffixes = (
                    ["", "-trixie"] if base["name"] == "trixie" else [base["suffix"]]
                )
                release_tags = [tag + suffix for tag in tags for suffix in suffixes]
                self.assertEqual(
                    commands[0],
                    [
                        "docker",
                        "buildx",
                        "imagetools",
                        "create",
                        *tag_args(release_tags),
                        *self.sources(base["name"]),
                    ],
                )

    def test_nightly_dated_tag(self) -> None:
        for base in BASES:
            suffixes = [base["suffix"], *base.get("aliases", [])]
            for status in (200, 404, 503):
                with self.subTest(base=base["name"], status=status):
                    commands = self.record_commands()
                    dates = self.fake_registry(
                        found=suffixes if status == 200 else (),
                        status="503" if status == 503 else None,
                    )
                    if status == 503:
                        with self.assertRaisesRegex(Fail, "HTTP 503"):
                            publish.publish(
                                IMAGE, "nightly", False, "digests", {}, base
                            )
                        self.assertEqual(
                            commands, [], "no tags changed on lookup error"
                        )
                        continue
                    publish.publish(IMAGE, "nightly", False, "digests", {}, base)
                    date = dates[-1]
                    dated = [f"{IMAGE}:nightly-{date}{suffix}" for suffix in suffixes]
                    expected = [
                        "docker",
                        "buildx",
                        "imagetools",
                        "create",
                        *tag_args(f"nightly{suffix}" for suffix in suffixes),
                    ]
                    if status == 404:
                        expected += [arg for tag in dated for arg in ("-t", tag)]
                    expected += self.sources(base["name"])
                    self.assertEqual(
                        commands[0], expected, "dated tag is created only when absent"
                    )
                    self.assertEqual(
                        commands[-1][-1],
                        dated[-1],
                        "dated tag inspected even if preserved",
                    )

    def test_release_aliases_share_one_index(self) -> None:
        # Both release aliases are attached to one index, including moving tags.
        commands = self.record_commands()
        publish.publish(IMAGE, VERSION, True, "digests", {}, BASES[0])
        self.assertEqual(
            commands[0],
            [
                "docker",
                "buildx",
                "imagetools",
                "create",
                *tag_args(
                    [
                        "0.10.10",
                        "0.10.10-trixie",
                        "0.10.10-bbb",
                        "0.10.10-bbb-trixie",
                        "0.10",
                        "0.10-trixie",
                        "latest",
                        "latest-trixie",
                    ]
                ),
                *self.sources("trixie"),
            ],
        )

    def test_missing_dated_alias_copies_existing_index(self) -> None:
        # Adding an alias mid-day (or retrying a partial publication) must preserve the
        # original dated image. Either spelling can be the surviving tag.
        for existing_suffix in ("", "-trixie"):
            with self.subTest(existing_suffix=existing_suffix):
                commands = self.record_commands()
                dates = self.fake_registry(found=[existing_suffix])
                publish.publish(IMAGE, "nightly", False, "digests", {}, BASES[0])
                date = dates[-1]
                missing_suffix = "-trixie" if existing_suffix == "" else ""
                self.assertEqual(
                    commands[0],
                    [
                        "docker",
                        "buildx",
                        "imagetools",
                        "create",
                        "-t",
                        f"{IMAGE}:nightly-{date}{missing_suffix}",
                        f"{IMAGE}:nightly-{date}{existing_suffix}",
                    ],
                )
                self.assertEqual(
                    commands[1],
                    [
                        "docker",
                        "buildx",
                        "imagetools",
                        "create",
                        *tag_args(["nightly", "nightly-trixie"]),
                        *self.sources("trixie"),
                    ],
                    "only mutable nightly aliases receive the new build",
                )

    def test_invalid_aliases_rejected(self) -> None:
        # Invalid aliases must fail before any publication can start.
        for aliases in (
            ["-bookworm"],
            ["-trixie", "-trixie"],
            ["bad suffix"],
            "not-an-array",
        ):
            with self.subTest(aliases=aliases):
                publish.write_json(
                    "bases.json", [{**BASES[0], "aliases": aliases}, BASES[1]]
                )
                with self.assertRaisesRegex(
                    Fail, "Duplicate tag suffix|Invalid tag suffix|Expected alias array"
                ):
                    publish.read_bases()

    def test_unsupported_platform_rejected(self) -> None:
        for invalid in (
            {"architectures": ["amd64"]},
            {"os": "windows"},
            {"runner": "windows-2022"},
        ):
            with self.subTest(invalid=invalid):
                publish.write_json("bases.json", [{**BASES[0], **invalid}, BASES[1]])
                with self.assertRaisesRegex(
                    Fail, "Invalid base architectures|Unsupported base platform"
                ):
                    publish.read_bases()

    def test_incomplete_base_does_not_block_others(self) -> None:
        # One base's incomplete architecture set does not prevent another publication.
        os.unlink("digests/trixie/arm64.digest")
        commands = self.record_commands()
        with self.assertRaisesRegex(Fail, "Missing arm64"):
            publish.publish(IMAGE, VERSION, False, "digests", {}, BASES[0])
        self.assertEqual(commands, [], "failed base publishes nothing")
        publish.publish(IMAGE, VERSION, False, "digests", {}, BASES[1])
        self.assertTrue(commands, "another base can still publish")

    def test_receipt_follows_successful_publication(self) -> None:
        # Publisher never commits history; receipts follow successful publication only.
        self.enterContext(
            mock.patch.dict(
                os.environ,
                {
                    "IMAGE": IMAGE,
                    "VERSION": VERSION,
                    "BASE": "bookworm",
                    "DIGEST_DIR": "digests",
                    "RECEIPT_DIR": "receipts",
                },
            )
        )

        def fail_docker(*args: str) -> None:
            if args[0] == "docker":
                raise Fail("docker failed")

        with (
            mock.patch.object(publish, "run", fail_docker),
            self.assertRaisesRegex(Fail, "docker failed"),
        ):
            publish.main()
        self.assertFalse(
            os.path.exists("receipts/bookworm.json"),
            "failed publication creates no receipt",
        )
        commands = self.record_commands()
        publish.main()
        self.assertEqual(
            publish.read_json("receipts/bookworm.json"),
            {"base": "bookworm", "version": VERSION},
        )
        self.assertFalse(
            [c for c in commands if c[:2] == ["git", "push"]],
            "publisher cannot push history",
        )


class ReleaseTest(WorkspaceTest):
    def setUp(self) -> None:
        super().setUp()
        os.mkdir("receipts")
        publish.write_json(
            "receipts/bookworm.json", {"base": "bookworm", "version": VERSION}
        )

    def test_merge_receipts(self) -> None:
        merged = {}
        self.assertTrue(
            release.merge_receipts(merged, "receipts", VERSION, BASES),
            "partial success recorded",
        )
        self.assertEqual(
            merged, {"bookworm": [VERSION]}, "only successful base recorded"
        )
        self.assertFalse(
            release.merge_receipts(merged, "receipts", VERSION, BASES),
            "duplicate receipt is idempotent",
        )
        self.assertFalse(
            release.merge_receipts({}, "absent", VERSION, BASES),
            "no successful publications is a no-op",
        )

    def test_invalid_receipts_rejected(self) -> None:
        for name, receipt in (
            ("trixie", {"base": "trixie", "version": "0.10.9+aaa"}),
            ("unknown", {"base": "unknown", "version": VERSION}),
        ):
            with self.subTest(name):
                publish.write_json(f"receipts/{name}.json", receipt)
                untouched = {}
                with self.assertRaisesRegex(Fail, "Invalid publication receipt"):
                    release.merge_receipts(untouched, "receipts", VERSION, BASES)
                self.assertEqual(
                    untouched, {}, "invalid receipts do not partially alter history"
                )
                os.unlink(f"receipts/{name}.json")

    def test_select_bases(self) -> None:
        history = {"bookworm": [VERSION]}
        self.assertEqual(
            release.select_bases(BASES, history, VERSION, "all", False),
            [base for base in BASES if base["name"] != "bookworm"],
            "retry only unpublished bases",
        )
        self.assertEqual(
            release.select_bases(BASES, history, VERSION, "bookworm", False),
            [],
            "published selection skips",
        )
        self.assertEqual(
            release.select_bases(BASES, history, VERSION, "bookworm", True),
            [BASES[1]],
            "explicit rebuild allowed",
        )
        self.assertEqual(
            release.select_bases(BASES, history, "0.10.11+ccc", "all", False),
            BASES,
            "new latest supersedes old pending releases",
        )
        self.assertEqual(
            release.select_bases(BASES, history, "nightly", "all", False),
            BASES,
            "nightly always selects every base",
        )
        complete = {base["name"]: [VERSION] for base in BASES}
        self.assertEqual(
            release.select_bases(BASES, complete, VERSION, "all", False),
            [],
            "all published skips build",
        )
        with self.assertRaisesRegex(Fail, "Unknown base"):
            release.select_bases(BASES, {}, VERSION, "unknown-base", False)

    def test_record(self) -> None:
        self.enterContext(
            mock.patch.dict(
                os.environ,
                {
                    "VERSION": VERSION,
                    "RECEIPT_DIR": "receipts",
                    "TARGETS": json.dumps({"include": BASES}),
                },
            )
        )
        commands = self.record_commands()
        release.record()
        self.assertEqual(
            publish.read_versions("versions.json"),
            {"bookworm": [VERSION]},
            "collector persists partial successes",
        )
        self.assertEqual(commands[-1], ["git", "push"], "one collector pushes history")
        commands.clear()
        release.record()
        self.assertEqual(
            commands,
            [["git", "pull", "--ff-only"]],
            "collector rerun does not create duplicate commit",
        )
        publish.write_json("versions.json", {})

        def fail_push(*args: str) -> None:
            if args[1] == "push":
                raise Fail("push failed")

        with (
            mock.patch.object(publish, "run", fail_push),
            self.assertRaisesRegex(Fail, "push failed"),
        ):
            release.record()

    def test_prepare(self) -> None:
        # The resolver emits a usable matrix and refreshes history before selection.
        publish.write_json("versions.json", {"bookworm": [VERSION]})
        self.enterContext(
            mock.patch.dict(
                os.environ,
                {
                    "CHANNEL": "release",
                    "INPUT_VERSION": "",
                    "INPUT_BASE": "all",
                    "GITHUB_OUTPUT": "outputs",
                },
            )
        )
        commands = self.record_commands()
        upstream = '{"items":[{"name":"moonc","version":"v0.10.10+bbb (date)"}]}'
        with mock.patch.object(publish, "capture", lambda *args: upstream):
            release.prepare()
        outputs = dict(
            line.split("=", 1) for line in Path("outputs").read_text().splitlines()
        )
        self.assertEqual(outputs["build"], "true", "resolver schedules missing bases")
        self.assertEqual(outputs["latest"], "true", "resolver identifies latest")
        self.assertEqual(outputs["version"], VERSION, "resolver strips prefix and date")
        self.assertEqual(
            json.loads(outputs["matrix"])["include"],
            [base for base in BASES if base["name"] != "bookworm"],
            "matrix matches retry selection",
        )
        self.assertEqual(
            commands[0],
            ["git", "pull", "--ff-only"],
            "history refreshed before selection",
        )


if __name__ == "__main__":
    unittest.main()
