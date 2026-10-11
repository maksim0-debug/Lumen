"""Regression coverage for release version resolution and workflow output."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from resolve_release_version import (
    compute_target_build_number,
    discover_previous_build_number,
    parse_pubspec_version,
    resolve_version,
)


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

    def test_parse_pubspec_version(self):
        cases = (
            ("version: 1.3.0+12\n", ("1.3.0", 12)),
            ("name: lumen\nversion: '2.0.0+42'\ndescription: test\n", ("2.0.0", 42)),
            ('version: "0.1.0-alpha+1"', ("0.1.0-alpha", 1)),
            ("version: 1.3.0\n", ("1.3.0", None)),
            ("name: lumen\n# version: 1.0.0+5\n", ("0.0.0", None)),
        )
        for content, expected in cases:
            with self.subTest(content=content):
                self.assertEqual(parse_pubspec_version(content), expected)

    def test_compute_target_build_number(self):
        # 1. Pubspec bumped ahead of previous release -> use pubspec
        self.assertEqual(compute_target_build_number(14, 12), (14, False))

        # 2. Pubspec equal to previous release -> auto-bump by 1
        self.assertEqual(compute_target_build_number(12, 12), (13, True))

        # 3. Pubspec lower than previous release -> auto-bump previous + 1
        self.assertEqual(compute_target_build_number(10, 12), (13, True))

        # 4. No previous release -> use pubspec
        self.assertEqual(compute_target_build_number(12, None), (12, False))

        # 5. Pubspec has no build number, previous release exists -> prev + 1
        self.assertEqual(compute_target_build_number(None, 12), (13, True))

        # 6. Neither exists -> default 1
        self.assertEqual(compute_target_build_number(None, None), (1, False))

    def test_discover_previous_build_number_in_current_repo(self):
        tag, build_num = discover_previous_build_number(target_ref="v1.3.1")
        self.assertEqual(tag, "v1.3.0")
        self.assertEqual(build_num, 12)

    def test_discover_previous_build_number_handles_utf8_cyrillic_safely(self):
        with tempfile.TemporaryDirectory(prefix="lumen_git_test_") as folder:
            repo_path = Path(folder)
            subprocess.run(["git", "init", "-q", "-b", "main"], cwd=repo_path, check=True)
            subprocess.run(["git", "config", "user.name", "Test Runner"], cwd=repo_path, check=True)
            subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=repo_path, check=True)

            pubspec = repo_path / "pubspec.yaml"
            pubspec.write_text(
                'name: lumen\ndescription: "Lumen — Сучасний додаток для графіків відключень"\nversion: 1.0.0+7\n',
                encoding="utf-8",
            )
            subprocess.run(["git", "add", "pubspec.yaml"], cwd=repo_path, check=True)
            subprocess.run(["git", "commit", "-m", "Initial commit"], cwd=repo_path, check=True)
            subprocess.run(["git", "tag", "v1.0.0"], cwd=repo_path, check=True)

            # Second commit
            pubspec.write_text(
                'name: lumen\ndescription: "Lumen — Сучасний додаток для графіків відключень"\nversion: 1.0.1+7\n',
                encoding="utf-8",
            )
            subprocess.run(["git", "commit", "-am", "Bump version"], cwd=repo_path, check=True)

            # Discover previous tag for upcoming v1.0.1
            prev_tag, prev_num = discover_previous_build_number(
                target_ref="v1.0.1",
                pubspec_path=pubspec,
                cwd=repo_path,
            )
            self.assertEqual(prev_tag, "v1.0.0")
            self.assertEqual(prev_num, 7)

    def test_command_writes_the_actual_tag_version_to_workflow_output(self):
        with tempfile.TemporaryDirectory(prefix="lumen_release_version_") as folder:
            output = Path(folder) / "output.txt"
            pubspec = Path(folder) / "pubspec.yaml"
            pubspec.write_text("name: lumen\nversion: 1.3.0+12\n", encoding="utf-8")
            output.write_text("previous=value\n", encoding="utf-8")
            subprocess.run(
                [sys.executable, str(Path(__file__).with_name("resolve_release_version.py"))],
                env={
                    **os.environ,
                    "RELEASE_TAG": "v1.3.1",
                    "GITHUB_OUTPUT": str(output),
                    "PUBSPEC_PATH": str(pubspec),
                    "PREV_BUILD_NUMBER": "12",
                },
                check=True,
                capture_output=True,
            )
            output_lines = output.read_text(encoding="utf-8").splitlines()
            self.assertIn("previous=value", output_lines)
            self.assertIn("clean_version=1.3.1", output_lines)
            self.assertIn("build_number=13", output_lines)
            self.assertIn("full_version=1.3.1+13", output_lines)
            self.assertIn("prev_build_number=12", output_lines)

    def test_full_version_strips_existing_plus_from_tag(self):
        with tempfile.TemporaryDirectory(prefix="lumen_release_version_") as folder:
            output = Path(folder) / "output.txt"
            pubspec = Path(folder) / "pubspec.yaml"
            pubspec.write_text("name: lumen\nversion: 1.3.0+12\n", encoding="utf-8")
            subprocess.run(
                [sys.executable, str(Path(__file__).with_name("resolve_release_version.py"))],
                env={
                    **os.environ,
                    "RELEASE_TAG": "v1.3.1+99",
                    "GITHUB_OUTPUT": str(output),
                    "PUBSPEC_PATH": str(pubspec),
                    "PREV_BUILD_NUMBER": "12",
                },
                check=True,
                capture_output=True,
            )
            output_lines = output.read_text(encoding="utf-8").splitlines()
            self.assertIn("clean_version=1.3.1+99", output_lines)
            self.assertIn("build_number=13", output_lines)
            self.assertIn("full_version=1.3.1+13", output_lines)


if __name__ == "__main__":
    unittest.main()

