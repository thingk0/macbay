#!/usr/bin/env python3
"""Reject GUI binaries whose linked SDK or deployment version differs from the build."""
import argparse
import re
import subprocess
import sys


def version(value):
    if not re.fullmatch(r"\d+(?:\.\d+){0,2}", value):
        raise ValueError("Invalid macOS version: " + value)
    parts = tuple(int(part) for part in value.split("."))
    return parts + (0,) * (3 - len(parts))


def verify_metadata(output, minimum, sdk):
    builds = re.findall(r"platform MACOS\s+minos (\S+)\s+sdk (\S+)", output)
    if not builds:
        raise ValueError("No macOS build-version metadata found")
    for actual_minimum, actual_sdk in builds:
        if version(actual_minimum) != version(minimum):
            raise ValueError(f"Minimum macOS changed: expected {minimum}, found {actual_minimum}")
        if version(actual_sdk) != version(sdk):
            raise ValueError(f"Linked SDK mismatch: expected {sdk}, found {actual_sdk}; native appearance may use compatibility styling")
    return len(builds)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary")
    parser.add_argument("--minimum", required=True)
    parser.add_argument("--sdk", required=True)
    args = parser.parse_args()
    try:
        output = subprocess.run(["xcrun", "vtool", "-show-build", args.binary],
                                check=True, text=True, capture_output=True).stdout
        verify_metadata(output, args.minimum, args.sdk)
    except (ValueError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        return 1
    print(f"macOS build verified: minimum {args.minimum}, SDK {args.sdk}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
