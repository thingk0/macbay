#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_arguments=(--debug)
app_arguments=()
for argument in "$@"; do
    case "$argument" in
        --demo) app_arguments+=(--demo) ;;
        --release) build_arguments=() ;;
        --help|-h)
            echo "Usage: scripts/run-app.sh [--demo] [--release]"
            echo "Build and open the native MacBay app. Defaults to a Debug build."
            echo "Quit an open MacBay first to load the rebuilt app or change demo mode."
            exit 0 ;;
        *) echo "Unknown argument: $argument" >&2; exit 2 ;;
    esac
done
bash "$repo_root/scripts/build-app.sh" "${build_arguments[@]}"
if [[ ${#app_arguments[@]} -gt 0 ]]; then
    open "$repo_root/.build/gui/MacBay.app" --args "${app_arguments[@]}"
else
    open "$repo_root/.build/gui/MacBay.app"
fi
