# Preparing the 1.10.0 desktop release

MacBay 1.10.0 adds the English native macOS app, connected storage gauges,
confirmed app and Xcode storage operations, selected cache cleanup, first-run
checks, Update Center, and supported Recovery Center actions.
See [GUI behavior](gui-poc.md) and [validation](validation-1.10.md).

## Local verification

```sh
bash scripts/test-safe.sh
python3 -m unittest discover -s Tests/PackagingTests -v
swift build -c release
bash scripts/build-app.sh --dmg
open .build/gui/MacBay.app
```

The safe runner excludes legacy CLI fixtures requiring physical external storage.
Tests use disposable fixtures and do not relocate real applications or delete
user caches. Local packaging produces an ad-hoc signed `.build/gui/MacBay.app`,
`MacBay-1.10.0-arm64-local.dmg`, and its SHA-256 checksum.
`MacBay-PoC.dmg` is a compatibility symlink. Use `--debug` for a Debug build.
These local artifacts are not notarized public downloads.

`Sources/MacBayKit/MacBayVersion.swift` supplies the GUI, CLI, TUI, and package
version. Packaging verifies the executable version and linked SDK, then stamps
`Info.plist`. `MACBAY_BUILD_NUMBER` optionally sets the build number.

## Signed distribution artifact

The existing packaging script supports Developer ID Application signing,
hardened runtime, notarization, and stapling through `--distribution`.
Use a Developer ID Application identity already available in Keychain and
an existing notarytool Keychain profile:

```sh
export MACBAY_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)'
export MACBAY_NOTARY_PROFILE='your-notary-profile'
bash scripts/build-app.sh --distribution
```

Instead of a Keychain profile, the script accepts `MACBAY_NOTARY_KEY_FILE`,
`MACBAY_NOTARY_KEY_ID`, and `MACBAY_NOTARY_ISSUER`. Keep signing keys, credentials,
and certificate exports outside the repository. Missing signing or notarization
settings stop the distribution build before compilation.

The script verifies the Developer ID signature, waits for notarization acceptance,
staples and validates both the app and DMG, assesses the app with Gatekeeper, and
writes `MacBay-1.10.0-arm64.dmg` with its checksum. Distribution requires a Release
build and an Apple Silicon build host.

## Review before publication

CI covers current and legacy GUI compilation, hardware-free tests, Release builds,
and a downloadable local verification DMG. Runner toolchains are documented in the
[macOS 26 image](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)
and [macOS 15 image](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md).

Before publishing, check the signed DMG on a separate Mac or user account with
normal quarantine and Gatekeeper checks. Verify setup, cancellation, appearance,
keyboard access, and accessibility preferences. Test interruptions with disposable
fixtures. Runtime checks on older supported macOS versions remain necessary.

Publishing notarized desktop releases and updating the Homebrew tap are separate
release work. This feature PR does not publish a release, create a version tag,
or add distribution credentials to GitHub Actions.
