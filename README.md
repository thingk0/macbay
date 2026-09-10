<p align="center">
  <img src="Assets/macbay-icon-concept.png" width="140" alt="MacBay logo">
</p>

<h1 align="center">MacBay</h1>

<p align="center">
  <a href="README.md">English</a> •
  <a href="docs/README.ko.md">한국어</a> •
  <a href="docs/README.zh.md">简体中文</a> •
  <a href="docs/README.ja.md">日本語</a>
</p>

MacBay is a developer-first storage externalizer designed for Apple Silicon Macs. It safely moves large applications, Xcode DeviceSupport data, and developer caches to an external APFS drive while transparently preserving the original paths for terminal CLIs, LaunchAgents, and the macOS Dock.

[![CI](https://github.com/thingk0/macbay/actions/workflows/ci.yml/badge.svg)](https://github.com/thingk0/macbay/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black.svg?logo=apple)](https://www.apple.com/macos/)
[![Apple Silicon](https://img.shields.io/badge/Architecture-Apple%20Silicon-orange.svg)](https://en.wikipedia.org/wiki/Apple_silicon)

---

## Features

- **Application Relocation (`dock` / `undock`)**: Migrate large apps to external storage and replace them with symbolic links. Dock icons and LaunchServices are automatically refreshed.
- **Safety Engine (`AppInspector`)**: Automatically checks application bundles for virtualization entitlements, kernel/system extensions, and hardcoded relocation signals.
- **Xcode DeviceSupport Management (`xcode`)**: Offload massive iOS DeviceSupport symbols while keeping Xcode functioning seamlessly. Preserves existing legacy links and cleans up unavailable simulators.
- **Developer Cache Routing (`cache`)**: Route npm, uv, Gradle, and Hugging Face caches to external storage via a clean, isolated block in `~/.zshrc`.
- **Strict Volume Validation**: Automatically validates external APFS filesystems and rejects installer DMGs, read-only drives, and internal disks.

---

## Supported Environment

- **macOS**: 13 (Ventura) or newer
- **Hardware**: Apple Silicon (M1 / M2 / M3 / M4)
- **External Storage**: Physical external SSD/HDD formatted as **APFS** (GUID Partition Map, writable)
- **Developer Tools**: Xcode Command Line Tools (`xcode-select --install`)

---

## Installation

### Method 1: Homebrew (Recommended)

Install MacBay using Homebrew:

```sh
brew install thingk0/tap/macbay
mb --help
```

Homebrew builds the binary directly from the tagged source release for Apple Silicon (macOS 13+). Both `mb` and the `macbay` alias are installed into your Homebrew `bin` directory.

#### Updating via Homebrew

```sh
brew update
brew upgrade macbay
```

#### Uninstalling via Homebrew

> [!CAUTION]
> `brew uninstall macbay` only removes the CLI executables (`mb` and `macbay`). It **does not** automatically restore relocated applications from external storage or reset `~/.zshrc` cache redirections.
>
> **Before uninstalling MacBay**, perform the following cleanup steps:
> 1. Restore any docked applications back to internal storage:
>    ```sh
>    mb undock <AppName>.app
>    ```
> 2. Reset the cache environment variables in `~/.zshrc`:
>    ```sh
>    mb cache --reset
>    ```
> 3. Now safely uninstall the formula:
>    ```sh
>    brew uninstall macbay
>    ```

---

### Method 2: Building from Source

Requirements: macOS 13 or newer, Apple Silicon, and Xcode Command Line Tools or Xcode 15.3+ (providing Swift 5.10 or newer).

```sh
# Clone the repository
git clone https://github.com/thingk0/macbay.git
cd macbay

# Build release binaries
swift build -c release

# Run tests
swift test

# Copy to /usr/local/bin (optional)
sudo cp .build/release/mb /usr/local/bin/mb
sudo ln -sf /usr/local/bin/mb /usr/local/bin/macbay
```

Verify installation:

```sh
mb --version
# Output: 1.0.0
```

---

## Quick Start

### 1. Check Storage Health

Inspect internal drive space, mounted external volumes, and any ineligible drives:

```sh
mb status
```

### 2. Discover Relocation Candidates

Scan for large applications and developer caches with safety assessments:

```sh
mb scan
```

Output example:
```text
MacBay scan
Threshold: 200.0 MB
Candidates: 8
  • [app] 🟢 SAFE Aside.app — 2.0 GB (/Applications/Aside.app)
  • [app] ⚠️ POPUP_RISK Claude.app — 825.2 MB (/Applications/Claude.app)
  • [app] ❌ BLOCKED OrbStack.app — 694.6 MB (/Applications/OrbStack.app)
  • [cache] CoreSimulator — 191.5 MB (/Users/.../Library/Developer/CoreSimulator)
  • [cache] npm cache — 124.2 MB (/Users/.../.npm)
```

---

## Commands & Usage

### Moving an Application (`dock`)

Moves an application bundle to the external volume and creates a symbolic link at `/Applications/<App>.app`.

```sh
# Always preview first with --dry-run
mb dock Example.app --dry-run

# Perform relocation
mb dock Example.app
```

**How it works**:
1. **Validation**: Checks bundle integrity, active processes (`lsof`), and SQLite locks (`-wal`, `-shm`).
2. **Compatibility**: Inspects code signature entitlements and relocation markers.
3. **Atomic Copy & Verify**: Copies the bundle via `ditto`, preserves metadata, and verifies with `codesign --verify --deep --strict`.
4. **Symlink Replacement**: Atomically swaps the original bundle with a symbolic link.
5. **System Refresh**: Rebuilds LaunchServices registration (`lsregister -f`) and restarts the Dock to avoid generic white icons.

> [!NOTE]
> If an application is flagged with ⚠️ **POPUP_RISK**, pass `--force` to proceed after reviewing potential risks:
> ```sh
> mb dock Claude.app --force --dry-run
> ```

### Restoring an Application (`undock`)

Restores an externalized application back to its original location in `/Applications` and cleans up the external copy:

```sh
# Preview restore
mb undock Example.app --dry-run

# Restore to internal disk
mb undock Example.app
```

### Xcode Maintenance (`xcode`)

Externalizes `~/Library/Developer/Xcode/iOS DeviceSupport` to the external volume and cleans up unavailable iOS simulators:

```sh
# Preview Xcode externalization
mb xcode --dry-run

# Execute Xcode maintenance
mb xcode
```

> [!TIP]
> If you already have a symlink pointing to an external volume (e.g. `/Volumes/<Drive>/Developer/Xcode/iOS DeviceSupport`), MacBay recognizes and validates the link target without unnecessary relocation.

### Developer Cache Routing (`cache`)

Routes developer package caches to external storage by adding a managed, isolated configuration block to `~/.zshrc`:

```sh
# Preview cache redirection
mb cache --enable --dry-run

# Enable external cache routing
mb cache --enable

# Reset and remove managed block from ~/.zshrc
mb cache --reset
```

Managed caches include:
- `npm`: `npm_config_cache`
- `uv`: `UV_CACHE_DIR`
- `Gradle`: `GRADLE_USER_HOME`
- `Hugging Face`: `HF_HOME`

---

## External Volume Requirements & Limits

To ensure data integrity, MacBay enforces strict volume eligibility criteria:

| Requirement | Rule | Rationale |
| :--- | :--- | :--- |
| **Mount Point** | Must be mounted under `/Volumes/` | Standard macOS external volume hierarchy |
| **Drive Type** | Physical external (`Internal == false`) | Avoids externalizing back onto the primary drive |
| **Filesystem** | **APFS** (`FilesystemType == apfs`) | Requires APFS clone/symlink/metadata capabilities |
| **Permissions** | Writable (`WritableVolume == true`) | Read-only drives cannot host application bundles |
| **Protocol** | `BusProtocol != "Disk Image"` | Rejects temporary installer DMGs automatically |

- **Auto-Selection**: When exactly one eligible external volume is mounted, MacBay automatically selects it.
- **Multiple Volumes**: When two or more eligible drives are connected, `--volume <path>` (or `-v`) is required to prevent accidental writes to the wrong drive.

---

## Safety Model & Compatibility Tiers

Before migrating any bundle, `AppInspector` grades the application:

- 🟢 **SAFE**: Clean bundle layout with no relocation hooks or virtualization requirements. Safe for standard relocation.
- ⚠️ **POPUP_RISK**: Application contains self-relocation checks (e.g., `moveToApplicationsFolder`, `PFMoveToApplicationsFolder` in Mach-O/ASAR) or privileged helper tools (`SMPrivilegedExecutables`). Requires the `-f, --force` flag to migrate.
- ❌ **BLOCKED**: Application requires hypervisor/virtualization entitlements (`com.apple.security.virtualization`), contains Driver/System/Kernel Extensions, or has corrupted code signatures. **Migration is blocked to prevent system instability.**

---

## External Layout

When externalizing, MacBay maintains the following structure on your external drive:

```text
/Volumes/<ExternalDrive>/MacBay/
├── Applications/       # Relocated application bundles
├── Caches/             # npm, uv, Gradle, and Hugging Face caches
├── Xcode/              # iOS DeviceSupport symbol caches
└── manifest.json       # Codable metadata manifest of all docked items
```

---

## JSON Output & Automation

Every command supports the `--json` flag for integration with scripts, CI, and agent tools:

```sh
mb status --json
```

On errors, MacBay outputs a structured error envelope to `stderr` and exits with a non-zero status:

```json
{
  "error": {
    "code": "configuration_error | retryable_error | execution_error",
    "message": "Application is blocked from migration (/Applications/OrbStack.app)",
    "details": "com.apple.security.virtualization=true in codesign entitlements"
  }
}
```

---

## Contributing

Contributions are welcome! Please read [CONTRIBUTING.md](CONTRIBUTING.md) for details on our code of conduct, hardware-free testing setup, and submission process.

---

## License

MacBay is open-source software licensed under the [MIT License](LICENSE). Copyright © 2026 thingk0.
