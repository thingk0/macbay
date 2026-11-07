#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
configuration=release
make_dmg=false
distribution=false
for argument in "$@"; do
    case "$argument" in
        --debug) configuration=debug ;;
        --dmg) make_dmg=true ;;
        --distribution) distribution=true; make_dmg=true ;;
        --help|-h)
            echo "Usage: scripts/build-app.sh [--debug] [--dmg] [--distribution]"
            echo "Default: locally ad-hoc signed .build/gui/MacBay.app."
            echo "--dmg creates a versioned local DMG; --distribution requires Developer ID and notarization."
            exit 0 ;;
        *) echo "Unknown argument: $argument" >&2; exit 2 ;;
    esac
done
if [[ "$distribution" == true ]]; then
    if [[ "$configuration" != release || -z "${MACBAY_SIGNING_IDENTITY:-}" ]]; then
        echo "Distribution requires a Release build and MACBAY_SIGNING_IDENTITY (Developer ID Application)." >&2
        exit 2
    fi
    if [[ -z "${MACBAY_NOTARY_PROFILE:-}" ]]; then
        for key in MACBAY_NOTARY_KEY_FILE MACBAY_NOTARY_KEY_ID MACBAY_NOTARY_ISSUER; do
            if [[ -z "${!key:-}" ]]; then echo "Missing notarization setting: $key" >&2; exit 2; fi
        done
    fi
fi
cd "$repo_root"
version="$(python3 scripts/read-version.py)"
build_number="${MACBAY_BUILD_NUMBER:-1}"
if [[ ! "$build_number" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then echo "Invalid MACBAY_BUILD_NUMBER" >&2; exit 2; fi
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
minimum_macos="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$repo_root/Packaging/MacBay/Info.plist")"
# Keep deployment support independent of the SDK that opts the app into native macOS styling.
# Some SwiftPM backends otherwise stamp the deployment version as the linked SDK.
build_options=(-c "$configuration" --sdk "$sdk_path"
    -Xlinker -platform_version -Xlinker macos -Xlinker "$minimum_macos" -Xlinker "$sdk_version")
swift build "${build_options[@]}" --product MacBayApp
bin_dir="$(swift build "${build_options[@]}" --show-bin-path)"
if [[ "$("$bin_dir/MacBayApp" --version)" != "$version" ]]; then echo "GUI version mismatch" >&2; exit 1; fi
python3 scripts/verify-macos-build.py "$bin_dir/MacBayApp" --minimum "$minimum_macos" --sdk "$sdk_version"
resource_bundle="$bin_dir/MacBay_MacBayGUI.bundle"
if [[ ! -d "$resource_bundle" ]]; then echo "Missing GUI resource bundle: $resource_bundle" >&2; exit 1; fi
if [[ "$(uname -m)" != arm64 ]]; then echo "MacBay distribution targets Apple Silicon (arm64)." >&2; exit 2; fi

output_dir="$repo_root/.build/gui"
mkdir -p "$output_dir"
staging_dir="$(mktemp -d "$output_dir/.macbay-build.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
app="$staging_dir/MacBay.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
ditto "$bin_dir/MacBayApp" "$app/Contents/MacOS/MacBayApp"
ditto "$resource_bundle" "$app/Contents/Resources/MacBay_MacBayGUI.bundle"
cp "$repo_root/Packaging/MacBay/Info.plist" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app/Contents/Info.plist"
cp "$repo_root/Assets/brand/MacBay.icns" "$app/Contents/Resources/MacBay.icns"
plutil -lint "$app/Contents/Info.plist"

notarize() {
    local artifact="$1"
    local result_file="$2"
    if [[ -n "${MACBAY_NOTARY_PROFILE:-}" ]]; then
        xcrun notarytool submit "$artifact" --keychain-profile "$MACBAY_NOTARY_PROFILE" --wait --output-format json > "$result_file"
    else
        xcrun notarytool submit "$artifact" --key "$MACBAY_NOTARY_KEY_FILE" --key-id "$MACBAY_NOTARY_KEY_ID" \
            --issuer "$MACBAY_NOTARY_ISSUER" --wait --output-format json > "$result_file"
    fi
    python3 - "$result_file" <<'PY'
import json, pathlib, sys
result = json.loads(pathlib.Path(sys.argv[1]).read_text())
if result.get("status") != "Accepted":
    print("Notarization was not accepted; submission ID: " + str(result.get("id", "unknown")), file=sys.stderr)
    sys.exit(1)
PY
}
if [[ "$distribution" == true ]]; then
    codesign --force --sign "$MACBAY_SIGNING_IDENTITY" --options runtime --timestamp "$app"
    signature_info="$(codesign -dv --verbose=4 "$app" 2>&1)"
    if [[ "$signature_info" != *"Authority=Developer ID Application:"* ]]; then
        echo "Distribution needs a Developer ID Application certificate." >&2; exit 2
    fi
    ditto -c -k --keepParent "$app" "$staging_dir/MacBay-notarization.zip"
    notarize "$staging_dir/MacBay-notarization.zip" "$staging_dir/app-notarization.json"
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    spctl --assess --type execute --verbose=2 "$app"
else
    codesign --force --sign - --timestamp=none "$app"
fi
codesign --verify --deep --strict "$app"
previous_app="$output_dir/MacBay.app"
if [[ -e "$previous_app" ]]; then
    identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$previous_app/Contents/Info.plist")"
    if [[ "$identifier" != "com.thingk0.macbay" ]]; then echo "Refusing to replace an unrelated app." >&2; exit 1; fi
    mv "$previous_app" "$staging_dir/previous-MacBay.app"
fi
if ! mv "$app" "$previous_app"; then
    if [[ -d "$staging_dir/previous-MacBay.app" ]]; then mv "$staging_dir/previous-MacBay.app" "$previous_app"; fi
    exit 1
fi
echo "App: $previous_app"
if [[ "$make_dmg" == true ]]; then
    suffix="-local"
    if [[ "$distribution" == true ]]; then suffix=""; fi
    dmg_name="MacBay-${version}-arm64${suffix}.dmg"
    dmg_root="$staging_dir/dmg"
    mkdir -p "$dmg_root"
    ditto "$previous_app" "$dmg_root/MacBay.app"
    ln -s /Applications "$dmg_root/Applications"
    dmg="$staging_dir/$dmg_name"
    hdiutil create -volname "MacBay" -srcfolder "$dmg_root" -format UDZO -ov "$dmg"
    if [[ "$distribution" == true ]]; then
        codesign --sign "$MACBAY_SIGNING_IDENTITY" --timestamp "$dmg"
        notarize "$dmg" "$staging_dir/dmg-notarization.json"
        xcrun stapler staple "$dmg"
        xcrun stapler validate "$dmg"
        codesign --verify --strict "$dmg"
    fi
    hdiutil verify "$dmg"
    mv -f "$dmg" "$output_dir/$dmg_name"
    (cd "$output_dir" && shasum -a 256 "$dmg_name" > "$dmg_name.sha256")
    if [[ "$distribution" == false ]]; then ln -sfn "$dmg_name" "$output_dir/MacBay-PoC.dmg"; fi
    echo "DMG: $output_dir/$dmg_name"
fi
if [[ "$distribution" == false ]]; then echo "Local verification artifact. Developer ID signing and notarization were not performed."; fi
