"""Regression coverage for release version resolution and workflow output."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from resolve_release_version import resolve_version


class ReleaseVersionTests(unittest.TestCase):
    def test_tag_prefix_and_semantic_version(self):
        for tag, expected in (
            ("v1.3.0", "1.3.0"),
            ("V2.0.0", "2.0.0"),
            ("1.3.0-rc.1+15", "1.3.0-rc.1+15"),
        ):
            with self.subTest(tag=tag):
                self.assertEqual(resolve_version(tag), expected)

    def test_branches_and_malformed_versions_are_rejected(self):
        for tag in (
            "", "main", "master", "v2.invalid", "v1.2", "v1.2.3.4",
            "v01.2.3", "v1.2.3-rc.01", "v1.2.3\nother=malicious",
        ):
            with self.subTest(tag=tag):
                with self.assertRaises(ValueError):
                    resolve_version(tag)

    def test_command_writes_the_actual_tag_version_to_workflow_output(self):
        with tempfile.TemporaryDirectory(prefix="lumen_release_version_") as folder:
            output = Path(folder) / "output.txt"
            output.write_text("previous=value\n", encoding="utf-8")
            subprocess.run(
                [sys.executable, str(Path(__file__).with_name("resolve_release_version.py"))],
                env={**os.environ, "RELEASE_TAG": "v1.3.0", "GITHUB_OUTPUT": str(output)},
                check=True,
                capture_output=True,
            )
            self.assertEqual(output.read_text(encoding="utf-8"),
                             "previous=value\nclean_version=1.3.0\n")


if __name__ == "__main__":
    unittest.main()
