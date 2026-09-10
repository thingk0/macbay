# Contributing to MacBay

Thank you for your interest in contributing to MacBay!

MacBay is a developer-first storage externalizer for Apple Silicon Macs that relocates large applications, Xcode data, and developer caches to external APFS storage while preserving symlinks and system integrity.

## Prerequisites

- **Operating System**: macOS 13 (Ventura) or newer
- **Hardware Architecture**: Apple Silicon (arm64)
- **Language / Toolchain**: Swift 5.10+ (Xcode 15.3+ or Command Line Tools)
- **Filesystem**: APFS for external volumes (in real use)

## Building the Project

### Debug Build

```sh
swift build
```

This builds the `MacBayKit` framework and both CLI executable targets:
- `.build/arm64-apple-macosx/debug/mb`
- `.build/arm64-apple-macosx/debug/macbay`

### Release Build

```sh
swift build -c release
```

The optimized binaries will be available under `.build/release/`.

## Running Tests

All unit and integration tests can be run using SwiftPM:

```sh
swift test
```

### Testing Guidelines & Safety Principles

1. **Hardware-Free Automated Testing**:
   Automated unit tests must never rely on physical external hardware or require root write access to `/Volumes`. Use `MockDiskInfoProvider` and configure `VolumeManager(volumeMountPrefix:)` with a temporary directory to simulate external APFS drives.

2. **No Real System Modifications in Tests**:
   Automated test suites must never move real applications from `/Applications`, delete user caches, or modify `~/.zshrc`. All file mutation tests must use temporary test sandboxes created in `setUpWithError()` and cleaned up in `tearDownWithError()`.

3. **Compatibility Engine Integrity**:
   Changes to bundle inspection must maintain the three compatibility tiers:
   - 🟢 `safe`: Portable applications with standard bundle layout.
   - ⚠️ `popupRisk`: Applications containing relocation prompts, self-relocation markers, or privileged helpers.
   - ❌ `blocked`: Applications with virtualization entitlements (`com.apple.security.virtualization`), kernel/system/driver extensions, or corrupted signatures.

4. **CLI Integration Verification**:
   When testing CLI behavior, run `swift build` first so debug binaries are up-to-date before running integration tests.

## Development Workflow

1. Fork the repository and create a feature branch (`git checkout -b feature/my-feature`).
2. Implement your changes adhering to existing Swift code style and safety rules.
3. Ensure all tests pass (`swift test`) and the release build compiles cleanly (`swift build -c release`).
4. Commit your changes with descriptive commit messages.
5. Submit a Pull Request.

## License

By contributing to MacBay, you agree that your contributions will be licensed under the project's [MIT License](LICENSE).
