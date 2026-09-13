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

MacBay uses two long-lived branches:

| Branch | Contains |
|--------|----------|
| `main` | Released code only. Every release is tagged here. Never commit to it directly. |
| `develop` | The default branch and the integration point for day-to-day work. |

Everything else is short-lived. Branch off `develop`, use kebab-case, and use the
prefix that matches the change:

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
git checkout develop
git pull
git checkout -b feat/support-custom-cache-path
```

### Releasing

A release moves `develop` into `main` and tags it. Homebrew builds from the tagged
source, so the tag is what users install.

```sh
git checkout -b release/1.2.0 develop
# bump the version in Sources/macbay/main.swift, update docs, commit
```

Open a pull request from `release/1.2.0` into `main`. Once it merges, tag the merge
commit on `main`:

```sh
git checkout main && git pull
git tag v1.2.0 && git push origin v1.2.0
```

The tag starts the `Release` workflow, which builds the optimized binaries, checks
that the tag matches the version the CLI reports, and publishes the GitHub release.

**Then merge `main` back into `develop`.** The release branch carries the version
bump, and `develop` needs it before the next feature lands.

### Hotfixes

An urgent fix to a released version branches off `main`, not `develop`:

```sh
git checkout -b hotfix/1.2.1 main
```

Open a pull request into `main`, tag it as above, then **merge `main` back into
`develop`**. Skipping that back-merge is the most common way a hotfix is lost: the
next release ships from `develop` without it.

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

1. **Branch off `develop`**: Ensure your branch is based on the latest `origin/develop`. Release and hotfix branches are the only ones that target `main`.
2. **Verify locally**:
   ```sh
   swift build -c release
   swift test
   ```
3. **Open a Pull Request**:
   - The **PR Title** must follow the Conventional Commits format (e.g. `feat(cli): add quiet mode flag`). A GitHub Action validates the title format automatically.
   - Describe the motivation, changes made, and how to test them in the PR body.
4. **CI Checks**:
   - `Build and Test (macOS)`: Builds the package and test targets, then runs the full test suite on macOS.
   - `Release Build (macOS)`: Builds the optimized binaries in parallel with the test job.
   - `Validate PR Title`: Verifies the PR title adheres to Conventional Commits.
   - `Release`: Runs only on a `v*` tag. Builds the optimized binaries, verifies the tag matches the
     reported version, and publishes the GitHub release.
   - `Build and Test` and `Release Build` run for pushes to `main` and for pull requests into `main` or `develop`.
     Direct pushes to `develop` skip them; start the `CI` workflow from the Actions tab when a change needs the
     Xcode 15.4 toolchain check before a release.
   - CI is skipped while a pull request is a draft, and for changes that only touch Markdown or `docs/`.
     A new push to the same branch cancels the run it supersedes.
5. **Merge Policy**:
   - **Squash and merge** is enforced for all PRs to maintain a clean linear Git history.
   - Head branches are automatically deleted upon merge.
   - All review conversations must be resolved prior to merging.

---

## License

By contributing to MacBay, you agree that your contributions will be licensed under the project's [MIT License](LICENSE).
