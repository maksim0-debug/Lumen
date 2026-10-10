"""Resolve the same release version for Android, Windows, and its installer."""

import os
from pathlib import Path
import re


_VERSION = re.compile(
    r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?"
    r"(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?"
)


def resolve_version(tag: str) -> str:
    version = tag.strip()
    if version.startswith(("v", "V")):
        version = version[1:]
    match = _VERSION.fullmatch(version)
    if match is None:
        raise ValueError("Release tag must contain a semantic version")
    prerelease = match.group(4)
    if prerelease and any(
        part.isdigit() and len(part) > 1 and part.startswith("0")
        for part in prerelease.split(".")
    ):
        raise ValueError("Numeric prerelease identifiers cannot have leading zeros")
    return version


def main() -> None:
    version = resolve_version(os.environ.get("RELEASE_TAG", ""))
    with Path(os.environ["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as output:
        output.write(f"clean_version={version}\n")


if __name__ == "__main__":
    main()
