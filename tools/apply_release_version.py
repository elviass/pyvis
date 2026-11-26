"""Set the build checkout's Flutter version from its release tag."""

from pathlib import Path
import re
import subprocess
import sys


def main(tag: str) -> None:
    match = re.fullmatch(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", tag)
    if match is None:
        raise SystemExit("Release tag must have the form vMAJOR.MINOR.PATCH (for example v0.1.2).")

    major, minor, patch = map(int, match.groups())
    if major > 255 or minor > 255 or patch > 65535:
        raise SystemExit("Release tag exceeds the Windows MSI version limits.")

    root = Path(__file__).resolve().parents[1]
    shallow = subprocess.check_output(
        ["git", "rev-parse", "--is-shallow-repository"], cwd=root, text=True
    ).strip()
    if shallow != "false":
        raise SystemExit("Release versioning requires a full Git checkout.")
    build = int(subprocess.check_output(
        ["git", "rev-list", "--count", "HEAD"], cwd=root, text=True
    ).strip())
    if not 1 <= build <= 65535:
        raise SystemExit("Build number exceeds the Windows executable version field.")

    version = f"{major}.{minor}.{patch}+{build}"
    pubspec = root / "client" / "pubspec.yaml"
    result, replacements = re.subn(
        rb"(?m)^version:[ \t]*[^\r\n]+", f"version: {version}".encode(), pubspec.read_bytes()
    )
    if replacements != 1:
        raise SystemExit("Expected exactly one top-level version in client/pubspec.yaml.")
    pubspec.write_bytes(result)
    print(f"Pyvis release version: {version}")


if __name__ == "__main__":
    main(sys.argv[1])
