#!/usr/bin/env python3
"""Read the single release version used by all MacBay executables."""
import pathlib
import re


def read_version(root: pathlib.Path) -> str:
    source = (root / "Sources/MacBayKit/MacBayVersion.swift").read_text()
    match = re.search(r'public static let current = "([^"]+)"', source)
    if not match or not re.fullmatch(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", match[1]):
        raise ValueError("MacBayVersion.current must contain a stable semantic version.")
    return match[1]


if __name__ == "__main__":
    print(read_version(pathlib.Path(__file__).resolve().parent.parent))
