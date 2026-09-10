# Contributing to MacBay

Thank you for your interest in contributing to MacBay!

MacBay is a developer-first storage externalizer for Apple Silicon Macs that relocates large applications, Xcode data, and developer caches to external APFS storage while preserving symlinks and system integrity.

---

## Prerequisites

- **Operating System**: macOS 13 (Ventura) or newer
- **Hardware Architecture**: Apple Silicon (arm64)
- **Language / Toolchain**: Swift 5.10+ (Xcode 15.3+ or Command Line Tools)
- **Filesystem**: APFS for external volumes (in real use)

---

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

---

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

---

## Branching & Commit Conventions

### Branch Strategy

All development is done via feature branches branched off `main`. Use kebab-case with the following standard prefixes:

| Branch Prefix | Purpose |
|---------------|---------|
| `feat/` | New features or CLI capabilities |
| `fix/` | Bug fixes and crash resolutions |
| `docs/` | Documentation updates (README, CONTRIBUTING, doc comments) |
| `refactor/` | Code refactoring without behavior change |
| `test/` | Adding, updating, or fixing tests |
| `perf/` | Performance optimizations |
| `build/` | Build scripts, dependencies, SwiftPM package manifests |
| `ci/` | CI/CD workflows and automated pipelines |
| `chore/` | Routine maintenance, repo hygiene, formatting |

Example:
```sh
git checkout -b feat/support-custom-cache-path
```

### Conventional Commits

MacBay strictly follows the [Conventional Commits 1.0.0](https://www.conventionalcommits.org/) specification for commit messages and Pull Request titles.

#### Format

```
<type>(<scope>): <subject>

[optional body]

[optional footer(s)]
```

#### Allowed Types

- `feat`: A new user-facing feature
- `fix`: A bug fix
- `docs`: Documentation-only changes
- `refactor`: Code changes that neither fix a bug nor add a feature
- `test`: Adding missing tests or correcting existing tests
- `perf`: Code changes that improve performance
- `build`: Changes that affect the build system or external dependencies
- `ci`: Changes to CI configuration files and scripts
- `chore`: Other changes that don't modify `src` or test files
- `revert`: Reverts a previous commit

#### Rules

1. **Imperative mood**: Use "add", "fix", "change", not "added", "fixes", "changing".
2. **Summary length**: Keep the first line within 72 characters.
3. **No trailing period**: Do not end the subject line with a period.
4. **Lowercase**: Start the subject with a lowercase letter.
5. **Breaking changes**: Indicate breaking changes by appending a `!` before the colon (e.g. `feat!: drop macOS 13 support`) or including `BREAKING CHANGE:` in the footer.

---

## Pull Request & Review Process

1. **Branch off `main`**: Ensure your branch is based on the latest `origin/main`.
2. **Verify locally**:
   ```sh
   swift build -c release
   swift test
   ```
3. **Open a Pull Request**:
   - The **PR Title** must follow the Conventional Commits format (e.g. `feat(cli): add quiet mode flag`). A GitHub Action validates the title format automatically.
   - Describe the motivation, changes made, and how to test them in the PR body.
4. **CI Checks**:
   - `Build and Test (macOS)`: Validates debug build, release build, and the full test suite on macOS.
   - `Validate PR Title`: Verifies the PR title adheres to Conventional Commits.
5. **Merge Policy**:
   - **Squash and merge** is enforced for all PRs to maintain a clean linear Git history.
   - Head branches are automatically deleted upon merge.
   - All review conversations must be resolved prior to merging.

---

## License

By contributing to MacBay, you agree that your contributions will be licensed under the project's [MIT License](LICENSE).
