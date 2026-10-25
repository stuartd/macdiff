#!/usr/bin/env python3
"""Check the metadata embedded in local, tagged, and source-archive builds."""

import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "generate-build-info.sh"


class BuildMetadataTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repository = self.root / "repository"
        self.repository.mkdir()
        self.output = self.root / "generated"
        self.environment = {
            "PATH": os.defpath,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": os.devnull,
        }
        self.git("init")
        self.git("-c", "user.name=MacDiff Test", "-c", "user.email=test@example.invalid",
                 "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
                 "commit", "--allow-empty", "-m", "Fixture")

    def git(self, *arguments):
        return subprocess.check_output(
            ["git", "-C", str(self.repository), *arguments],
            env=self.environment, text=True, stderr=subprocess.DEVNULL,
        ).strip()

    def metadata(self, project=None, **overrides):
        subprocess.run(
            ["sh", str(SCRIPT), str(project or self.repository), str(self.output)],
            env={**self.environment, **overrides}, check=True, capture_output=True,
        )
        source = (self.output / "BuildMetadata.swift").read_text()
        return dict(re.findall(r'^    static let (\w+) = "([^"\n]*)"$', source, re.MULTILINE))

    def test_local_build_uses_checkout_commit_and_records_build_time(self):
        metadata = self.metadata(GITHUB_SHA="a" * 40)
        self.assertEqual(metadata["commit"], self.git("rev-parse", "--short", "HEAD")[:12])
        self.assertEqual(metadata["releaseTag"], "")
        self.assertRegex(metadata["date"], r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} UTC$")

    def test_tagged_release_preserves_the_full_tag(self):
        for tag in ["v1.0", "v1.0-rc.1", "v1.0+build.2"]:
            with self.subTest(tag=tag):
                self.assertEqual(self.metadata(MACDIFF_RELEASE_TAG=tag)["releaseTag"], tag)

    def test_rebuilding_without_release_tag_does_not_retain_it(self):
        self.metadata(MACDIFF_RELEASE_TAG="v1.0")
        self.assertEqual(self.metadata()["releaseTag"], "")

    def test_archive_build_uses_github_commit_or_unavailable(self):
        archive = self.root / "archive"
        archive.mkdir()
        self.assertEqual(self.metadata(project=archive, GITHUB_SHA="b" * 40)["commit"], "b" * 12)
        self.assertEqual(self.metadata(project=archive)["commit"], "Unavailable")

    def test_unsafe_values_are_not_embedded_in_swift_source(self):
        archive = self.root / "archive"
        archive.mkdir()
        for value in ['v1.0"', "v1.0\ninvalid", "$(invalid)"]:
            with self.subTest(value=value):
                metadata = self.metadata(project=archive, GITHUB_SHA=value, MACDIFF_RELEASE_TAG=value)
                self.assertEqual(metadata["commit"], "Unavailable")
                self.assertEqual(metadata["releaseTag"], "")


if __name__ == "__main__":
    unittest.main()
