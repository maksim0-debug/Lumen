"""Resolve the same release version and smart monotonic build number for Android, Windows, and its installer."""

import os
from pathlib import Path
import re
import subprocess
import sys


_VERSION = re.compile(
    r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?"
    r"(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?"
)

_PUBSPEC_VERSION_RE = re.compile(
    r"^[ \t]*version:[ \t]*['\"]?([^+'\"\s\r\n#]+)(?:\+([0-9]+))?['\"]?",
    re.MULTILINE,
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


def parse_pubspec_version(content: str) -> tuple[str, int | None]:
    match = _PUBSPEC_VERSION_RE.search(content)
    if not match:
        return "0.0.0", None
    version_name = match.group(1).strip()
    build_num_str = match.group(2)
    build_number = int(build_num_str) if build_num_str else None
    return version_name, build_number


def get_pubspec_build_info(pubspec_path: Path) -> tuple[str, int | None]:
    if not pubspec_path.is_file():
        return "0.0.0", None
    try:
        content = pubspec_path.read_text(encoding="utf-8")
        return parse_pubspec_version(content)
    except Exception as err:
        print(f"Warning: could not read {pubspec_path}: {err}", file=sys.stderr)
        return "0.0.0", None


def compute_target_build_number(
    pubspec_num: int | None,
    prev_num: int | None,
) -> tuple[int, bool]:
    current_num = pubspec_num if pubspec_num is not None else 1
    if prev_num is None:
        return current_num, False
    if pubspec_num is not None and pubspec_num > prev_num:
        return pubspec_num, False
    bumped = prev_num + 1
    return bumped, True


def discover_previous_build_number(
    target_ref: str = "HEAD",
    pubspec_path: Path | None = None,
    cwd: Path | None = None,
) -> tuple[str | None, int | None]:
    try:
        ref_to_inspect = target_ref.strip() or "HEAD"
        verify_res = subprocess.run(
            ["git", "rev-parse", "-q", "--verify", ref_to_inspect],
            cwd=cwd,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=False,
        )
        if verify_res.returncode == 0 and ref_to_inspect != "HEAD":
            target_lookup = f"{ref_to_inspect}^"
        else:
            target_lookup = "HEAD"

        desc_res = subprocess.run(
            ["git", "describe", "--tags", "--abbrev=0", target_lookup],
            cwd=cwd,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=False,
        )
        prev_tag = desc_res.stdout.strip() if desc_res.returncode == 0 else ""

        if not prev_tag:
            tag_list_res = subprocess.run(
                ["git", "tag", "-l", "--sort=-creatordate", "v*"],
                cwd=cwd,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                check=False,
            )
            if tag_list_res.returncode == 0:
                tags = [t.strip() for t in tag_list_res.stdout.splitlines() if t.strip()]
                target_clean = ref_to_inspect.lstrip("vV")
                for candidate in tags:
                    candidate_clean = candidate.lstrip("vV")
                    if candidate != ref_to_inspect and candidate_clean != target_clean:
                        prev_tag = candidate
                        break

        if not prev_tag:
            return None, None

        if pubspec_path is not None:
            try:
                base_dir = cwd if cwd is not None else Path.cwd()
                rel_pubspec = pubspec_path.resolve().relative_to(base_dir.resolve()).as_posix()
            except ValueError:
                rel_pubspec = "pubspec.yaml"
        else:
            rel_pubspec = "pubspec.yaml"

        show_res = subprocess.run(
            ["git", "show", f"{prev_tag}:{rel_pubspec}"],
            cwd=cwd,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=False,
        )
        if show_res.returncode == 0 and show_res.stdout:
            _, prev_build_num = parse_pubspec_version(show_res.stdout)
            return prev_tag, prev_build_num

        return prev_tag, None
    except Exception as err:
        print(f"Notice: git inspection failed ({err}), proceeding without previous release tag.", file=sys.stderr)
        return None, None


def main() -> None:
    raw_tag = os.environ.get("RELEASE_TAG", "")
    version = resolve_version(raw_tag)

    pubspec_path = Path(os.environ.get("PUBSPEC_PATH", "pubspec.yaml"))
    _, pubspec_build_num = get_pubspec_build_info(pubspec_path)

    prev_override = os.environ.get("PREV_BUILD_NUMBER")
    if prev_override is not None and prev_override.strip().isdigit():
        prev_tag = "override"
        prev_build_num = int(prev_override.strip())
    else:
        prev_tag, prev_build_num = discover_previous_build_number(
            target_ref=raw_tag,
            pubspec_path=pubspec_path,
        )

    target_build_num, is_auto_bumped = compute_target_build_number(
        pubspec_build_num,
        prev_build_num,
    )

    print(f"Resolved release version: {version}")
    print(f"Pubspec build number: {pubspec_build_num}")
    print(f"Previous release build number: {prev_build_num} (tag: {prev_tag or 'none'})")
    print(f"Target build number: {target_build_num}")

    if is_auto_bumped:
        print(
            f"⚠️ Notice: pubspec.yaml build number ({pubspec_build_num}) was not greater than "
            f"previous release ({prev_build_num}). Auto-bumped to {target_build_num} to ensure Android "
            f"update compatibility.",
            file=sys.stderr,
        )

    base_version = version.split("+")[0]
    github_output = os.environ.get("GITHUB_OUTPUT")
    if github_output:
        with Path(github_output).open("a", encoding="utf-8") as output:
            output.write(f"clean_version={version}\n")
            output.write(f"build_number={target_build_num}\n")
            output.write(f"full_version={base_version}+{target_build_num}\n")
            output.write(f"prev_build_number={prev_build_num if prev_build_num is not None else ''}\n")


if __name__ == "__main__":
    main()
