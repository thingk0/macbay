<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Assets/brand/macbay-symbol-dark.svg">
    <img src="Assets/brand/macbay-symbol-color.svg" width="140" height="140" alt="MacBay logo">
  </picture>
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
[![Apple Silicon](https://img.shields.io/badge/Architecture-Apple%20Silicon-orange.svg)](https://en.wikipedia.org/wiki/Apple_silicon) [![Sponsor](https://img.shields.io/badge/Sponsor-thingk0-ea4aaa?logo=github-sponsors)](https://github.com/sponsors/thingk0)

---

## Features

- **Interactive TUI Mode (`mb` / `mb tui`)**: Launch a keyboard-driven Terminal User Interface directly by typing `mb` in an interactive terminal. Inspect storage capacity, browse applications with Safe/Review/Blocked status, safely preview and execute moves and restorations, and explore diagnostic findings with actionable recommendations.
- **Application Relocation (`dock` / `undock` / `adopt`)**: Migrate large apps to external storage, restore them to internal disk, or adopt already-externalized apps into standard MacBay layout without restoring first. Dock icons and LaunchServices are automatically refreshed.
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
# Output: 1.2.1
```

---

## Quick Start

### 0. Interactive TUI Mode (Default)

Simply run `mb` without arguments in your terminal to open the keyboard-driven TUI:

```sh
mb
# Or explicitly:
mb tui
```

> [!NOTE]
> In non-interactive environments (CI, scripts, pipes) or when `TERM` is unsupported, `mb` prints standard CLI help to stdout. Explicit `mb tui` in a non-interactive environment exits with an error explanation.

#### Keyboard Controls

| Key | Action |
| --- | --- |
| `↑` / `↓` or `j` / `k` | Navigate items and menus |
| `Enter` | Select menu item or proceed with action |
| `Esc` | Go back to previous screen |
| `q` | Quit MacBay TUI |
| `r` | Refresh current screen data |
| `←` / `→` or `Tab` | Switch between buttons (Cancel / Confirm) |

#### TUI Scope

- **Home**: Inspect internal/external disk capacity and managed application counts.
- **Move Application (`dock`)**: Browse application candidates sorted by size with `[Safe]`, `[Review]`, and `[Blocked]` status badges. Inspect bundle details, review relocation risks, select session target volume, and preview dry-run space changes before confirming.
- **Restore Application (`undock`)**: Restore connected MacBay-managed applications back to internal storage. Unmanaged apps can be adopted straight from this screen: review the current location, standard storage path, link change, and whether the bundle actually moves, then confirm. Adoption targets the volume that really holds the app, never the configured default, and the restore preview is prepared only after that confirmation. Unconfirmed or broken links display status and `mb doctor` guidance.
- **Diagnosis (`doctor`)**: Inspect externalized apps and developer data for broken links, missing targets, record mismatches, and interrupted operations, with actionable recommendations highlighted for each issue.
- *(Note: Multi-select, search, and Xcode/cache/repair execution will be introduced in subsequent versions. Use CLI commands for those workflows.)*

### 1. Check Storage Health

Inspect internal drive space, mounted external volumes, and any ineligible drives:

```sh
mb status
```

Output example:
```text
MacBay storage status

Internal · Macintosh HD
  /
  ████████░░░░░░░░░░░░  42.2% used
  Used: 96.3 GB / 228.3 GB
  Free: 132.0 GB

External · ExternalSSD
  /Volumes/ExternalSSD
  ████░░░░░░░░░░░░░░░░  20.5% used
  Used: 205.0 GB / 1000.0 GB
  Free: 795.0 GB

Docked items · 0
  None

Warnings · 2
  • Excluded volume 'InstallerImage' (/Volumes/InstallerImage): Disk image volumes are not supported
  • Excluded volume 'ToolInstaller' (/Volumes/ToolInstaller): Disk image volumes are not supported
```

### 2. Discover Relocation Candidates

Scan for large applications, developer caches, already externalized applications, and broken links:

```sh
mb scan
```

Output example:
```text
MacBay scan
8 apps · 2 caches · 2 external
App threshold: 200.0 MB

Applications · 8
  NAME                    SIZE  STATUS
  HeavyStudio.app       2.1 GB  Review
  VirtualMachine.app    1.8 GB  Blocked
  ContainerRuntime.app  1.2 GB  Blocked
  DeveloperIDE.app    850.0 MB  Safe
  CloudStorage.app    620.4 MB  Safe
  SystemHelper.app    410.2 MB  Review
  DriverDaemon.app    320.0 MB  Blocked
  Messenger.app       240.5 MB  Safe

  Safe: no relocation signals detected
  Review: check compatibility details before using --force
  Blocked: migration not allowed

Developer caches · 2
  CoreSimulator  191.5 MB
  npm cache      124.2 MB

Already external · 2
  DesignKit.app    1.5 GB  Unmanaged
    → /Volumes/ExternalSSD/Applications/DesignKit.app
  AudioEngine.app  1.2 GB  MacBay
    → /Volumes/ExternalSSD/MacBay/Applications/AudioEngine.app

  MacBay: recorded in volume manifest
  Unmanaged: no matching MacBay migration record
```

To see full bundle paths and detailed compatibility reasons/evidence:
```sh
mb scan --verbose
```

- **Applications**: Local apps (≥ 200 MB) with compatibility status (`Safe`, `Review`, `Blocked`).
- **Developer caches**: Large developer tool caches (e.g. CoreSimulator, npm cache).
- **Already external**: Applications already relocated to external storage:
  - `MacBay`: Recorded and managed in the external volume's `manifest.json`.
  - `Unmanaged`: Relocated manually or outside of MacBay.
  - `Unconfirmed`: Target is on external storage, but manifest reading failed.
- **Unresolved links**: Broken symlinks (`Target unavailable`), circular symlinks, or failed volume checks.

### 3. Diagnose Links and Records

Verify that application links, developer cache links, and the MacBay records on connected volumes still agree. `doctor` is read-only and never changes files:

```sh
mb doctor
```

Output example:
```text
MacBay doctor

Volumes consulted · 1
  • ExternalSSD (/Volumes/ExternalSSD) — 2 records

Needs attention · 1
  ! OfflineApp.app — Target unavailable: /Volumes/ExternalSSD/MacBay/Applications/OfflineApp.app
    Next: Reconnect the volume or confirm the path exists, then run 'mb doctor' again.

Healthy · 2
  • AudioEngine.app → /Volumes/ExternalSSD/MacBay/Applications/AudioEngine.app [MacBay]
  • LegacyTool.app → /Volumes/Backup/LegacyTool.app [unmanaged]
```

- `Healthy`: The link resolves and matches its MacBay record or the MacBay layout. Links without a record are shown as `unmanaged` information, not as problems.
- `Needs attention`: Broken links, circular links, records that disagree with the actual target path, records whose recorded copy or source path is missing, and local data that appeared where a recorded link should be.
- `Unable to verify`: The link, the link target volume, or a volume's `manifest.json` could not be read (for example permission or manifest errors).
- `Notes` state the scope of the check, including that manually relocated items have no MacBay history and are not evaluated, and that items on a volume whose records could not be read were not checked.
- `Nothing to verify` (no records or relocated links were found) is reported separately from "no problems found".

Exit codes: `0` when nothing needs attention, `1` when problems or unverifiable items were found, `2` when the check itself failed (for example an unreadable `--volume` path).

> [!NOTE]
> MacBay only reads records from connected external volumes, so a detached drive cannot be verified. Diagnostics report the scope that was actually checked and do not assume that a missing target was ejected or deleted.

---

## Commands & Usage

### Choosing the Default Volume (`init`)

Saves the external volume that mutating commands use when `--volume` is omitted, so `dock`, `undock`, `adopt`, `xcode`, and `cache` keep targeting the same drive:

```sh
# Save the only eligible volume, or pick from a numbered list in a terminal
mb init

# Save a specific volume without prompting
mb init --volume /Volumes/ExternalSSD

# Print the saved default
mb init --show

# Remove the saved default
mb init --reset
```

The saved default is written to `$XDG_CONFIG_HOME/macbay/config.json` (or `~/.config/macbay/config.json`) together with the volume UUID, so the default is still recognized when the drive mounts under a different name. If the saved volume is not connected, mutating commands stop instead of writing to another drive; `mb status` and `mb doctor` report the situation, and running `mb init` again replaces the default after confirmation.

### Diagnosing Links and Records (`doctor`)

Inspects `/Applications` links, known developer cache links, and the MacBay records on connected external volumes (including read-only volumes). It never writes files or configuration:

```sh
# Diagnose the connected volumes and local links
mb doctor

# Inspect an additional volume that is not mounted under /Volumes
mb doctor --volume /Volumes/Archive
```

**What it checks**:
1. **Application links**: Every symlink in `/Applications` is resolved (relative, chained, and circular links included).
2. **Developer cache links**: `~/Library/Developer/Xcode/iOS DeviceSupport`, `~/Library/Developer/CoreSimulator`, `~/.npm`, `~/.cache/uv`, `~/.gradle`, and `~/.cache/huggingface`.
3. **Volume records**: Each connected volume's `MacBay/manifest.json` is compared against the real source and target paths.
4. **Local data**: A recorded source path that is no longer a link but exists as a regular file or directory is reported as `Local data detected`, together with both paths and their current sizes. If the recorded copy is also missing, it is reported as a mismatch between the record and reality rather than as a duplicate.
5. **Interrupted operations**: Incomplete `adopt` and `repair` operations left behind on a volume are reported with the command needed to roll back or finish.

> [!NOTE]
> `doctor` never deletes, overwrites, or re-moves anything, and it does not claim that local data was regenerated by an update or that two copies are identical. Manually relocated items have no MacBay history, so they are excluded from the local data check; the report states this scope in `notes`.

**Result groups**: `Healthy`, `Needs attention`, `Unable to verify`, plus `unmanaged` information for links that MacBay never created. Every problem includes a stable diagnostic code in `--json` output and a suggested next action.

**Exit codes**: `0` healthy, `1` problems or unverifiable items found, `2` the check itself failed.

> [!IMPORTANT]
> `doctor` is read-only. It does not delete, move, or repair anything, and it does not keep records on the internal drive, so a detached external volume cannot be verified until it is reconnected.

### Inspecting Stored App Paths (`references`)

Checks the app paths stored inside specific configuration files. Only the files passed with `--path` are read; nothing else on the disk is scanned:

```sh
# Inspect one file
mb references --path ~/.cursor/mcp.json

# Inspect several files (repeatable)
mb references --path ~/.cursor/mcp.json --path ~/Library/LaunchAgents/com.example.tool.plist
```

JSON and XML/binary plist files are read with Foundation; TOML, YAML, INI, shell, and similar text files are scanned for absolute paths that cross a `.app` boundary. Relative paths use the current directory and `~` uses the home directory; a repeated path is checked once. `/Applications` and `~/Applications` are consulted to confirm whether a stored path still exists and to find a replacement candidate — no volume or manifest checks run here.

When a stored path is missing, MacBay looks for a unique same-named app in `/Applications` and `~/Applications` (preferring `/Applications` when both resolve to the same real app). If the same internal path exists, the report uses `external_reference_stale_candidate` with the current candidate. If no replacement app or internal file exists, it uses `external_reference_missing`. Access errors, circular links, and ambiguous same-named apps are `external_reference_unverified`. Read limits are `external_reference_scan_incomplete`.

> [!NOTE]
> Reference checks are read-only. Heuristic extraction of path-like strings is a supported inspection method; MacBay does not expand shell variables, run scripts, or treat a setting's presence as proof that it is currently used. Known MCP sections (`mcp_servers` in TOML, `mcpServers` in JSON) skip explicitly disabled servers, and unsupported TOML constructs are reported as partially checked. A reported path is a candidate only — MacBay does not confirm that an app was moved or deleted, that two copies are the same version, or whether the setting is currently in use. Path wildcards, template tokens such as `<AppName>`, and the literal `AppName.app` placeholder are not checked as file references, and matches of that skip policy are excluded from findings and explained in `notes`. An unmounted external volume is mentioned as a possible cause when relevant. If a stored path looks wrong, first confirm the setting is currently in use, then back up the file and update the path (for example to `/Applications/<App>.app/...`). MacBay never edits those files.

> [!NOTE]
> Limits are 10,000 configuration files, 2 MiB per file, and 64 MiB total read. Backup files are skipped.

**Exit codes**: `0` when every stored path checks out, `1` when missing paths, unreadable files, or incomplete reads were found, `2` when the arguments are invalid or the check itself failed.

### Moving an Application (`dock`)

Moves an application bundle to the external volume and creates a symbolic link at `/Applications/<App>.app`.

```sh
# Always preview first with --dry-run
mb dock Example.app --dry-run

# Perform relocation
mb dock Example.app
```

Preview output example:
```text
Dry run: dock Example.app
  Size: 21.6 GB
  Source: /Applications/Example.app
  Destination: /Volumes/ExternalSSD/MacBay/Applications/Example.app
  Space: destination free 859.5 GB on /Volumes/ExternalSSD
  Space: estimated free after copy 837.9 GB
  Space: estimated internal space freed 21.6 GB (logical size estimate; APFS shared blocks and snapshots can change the actual amount)
  Dry run: no files were changed
```

The preview also reports the destination free space, the estimated free space after the copy, the space expected to be freed on the internal disk, and — when the destination is too small — the shortfall. These are conservative estimates based on logical file sizes, so APFS shared blocks and snapshots can change the actual amount. A real run re-checks free space and stops before copying anything if it is insufficient or cannot be verified; a sufficient estimate never guarantees that the migration will succeed.

**How it works**:
1. **Validation**: Checks bundle integrity, active processes (`lsof`), and SQLite locks (`-wal`, `-shm`).
2. **Compatibility**: Inspects code signature entitlements and relocation markers.
3. **Atomic Copy & Verify**: Copies the bundle via `ditto`, preserves metadata, and verifies with `codesign --verify --deep --strict`.
4. **Symlink Replacement**: Atomically swaps the original bundle with a symbolic link.
5. **System Refresh**: Rebuilds LaunchServices registration (`lsregister -f`) and restarts the Dock to avoid generic white icons.

> [!NOTE]
> If an application is flagged with ⚠️ **Review** (`POPUP_RISK` in JSON), pass `--force` to proceed after reviewing potential risks:
> ```sh
> mb dock HeavyStudio.app --force --dry-run
> ```

> [!TIP]
> If an application in `/Applications` is already a symlink pointing to external storage outside MacBay, `mb dock` detects this and suggests running `mb adopt` instead.

### Restoring an Application (`undock`)

Restores an externalized application back to its original location in `/Applications` and cleans up the external copy:

```sh
# Preview restore
mb undock Example.app --dry-run

# Restore to internal disk
mb undock Example.app
```

Restoring also previews the space requirement: the internal volume's free space, the estimated free space after the copy, and any shortfall. The internal volume is re-checked at run time, and the restore stops before copying when space is insufficient or cannot be verified.

### Adopting an External Application (`adopt`)

Adopts an application that already resides on external storage into the standard MacBay layout (`<Volume>/MacBay/Applications/<App>.app`), updates `/Applications/<App>.app` symlink, and registers it in `manifest.json` without copying it back to the internal disk first:

```sh
# Preview adoption with --dry-run
mb adopt ChatGPT.app --volume /Volumes/ExternalSSD --dry-run

# Execute adoption
mb adopt ChatGPT.app --volume /Volumes/ExternalSSD
```

Preview output example:
```text
Dry run: adopt ChatGPT.app
  Size: 120.5 MB
  Source: /Volumes/ExternalSSD/Applications/ChatGPT.app
  Destination: /Volumes/ExternalSSD/MacBay/Applications/ChatGPT.app
  Symlink: /Applications/ChatGPT.app -> /Volumes/ExternalSSD/MacBay/Applications/ChatGPT.app
  Space: no additional space required (same volume relocation)
  Dry run: no files were changed
```

**How it works**:
1. **Target Resolution**: Resolves the unmanaged symlink at `/Applications/<App>.app` to locate the source bundle on external APFS storage.
2. **Safety & Compatibility**: Checks for active processes (`lsof`), SQLite locks (`-wal`, `-shm`), codesign integrity, and migration blockers. Applications flagged with ⚠️ **Review** (`POPUP_RISK`) require `--force`.
3. **Journaling & Crash Recovery**: Writes an operation record (`.operations/adopt-<id>.json`) on the external volume. If interrupted, `mb doctor` reports the incomplete operation (`incomplete_operation`).
4. **Atomic Relocation**: Moves the bundle to `<Volume>/MacBay/Applications/<App>.app` within the same APFS volume, or skips the move if it is already at the standard destination.
5. **Atomic Symlink Update**: Swaps the `/Applications/<App>.app` symlink to point to the new MacBay path atomically.
6. **Manifest Registration**: Records the item in `MacBay/manifest.json` with multi-process file locking (`flock`).
7. **System Refresh**: Rebuilds LaunchServices registration (`lsregister -f`) and restarts the Dock.

### Repairing Duplicate Applications (`repair`)

When `mb doctor` detects that an application recorded in the manifest has a full duplicate bundle in `/Applications` again (e.g. from an installer or auto-updater) while the external copy still exists (`local_data_detected`), `mb repair` provides safe inspection, comparison, and recovery:

```sh
# 1. Read-only side-by-side comparison
mb repair "Kiro CLI.app"

# 2. Preview re-externalization (redock)
mb repair "Kiro CLI.app" --action redock --dry-run

# 3. Preview keeping the local copy and unmanaging
mb repair "Kiro CLI.app" --action keep-local --dry-run

# 4. Real execution
mb repair "Kiro CLI.app" --action redock
mb repair "Kiro CLI.app" --action keep-local

# 5. Rollback an interrupted operation
mb repair "Kiro CLI.app" --rollback
```

**Comparison output example**:
```text
Repair comparison · Kiro CLI.app
  Volume: /Volumes/ExternalSSD

Attributes               Local (/Applications)               External (MacBay)
───────────────────────  ──────────────────────────────────  ──────────────────────────────────
Identifier               com.kiro.cli                        com.kiro.cli
Version                  1.2.0                               1.1.0
Build                    120                                 110
Size                     105.4 MB                            98.2 MB
Signature                Valid                               Valid
Compatibility            Safe                                Safe

Available actions:
  • mb repair "Kiro CLI.app" --action redock
    Re-dock local app to external storage; backs up existing external copy
  • mb repair "Kiro CLI.app" --action keep-local
    Keep local app and remove migration record; external copy remains as unmanaged archive
```

**Safety & Backup Policy**:
- **Bundle ID Matching**: `redock` strictly verifies that bundle identifiers match before proceeding. If IDs differ, `redock` is refused to prevent accidental overwrites.
- **External Backup Retention**: When executing `redock`, the existing external copy is moved to `<Volume>/MacBay/Backups/<OperationID>/<App>.app` before the new copy is placed. External backups are preserved and never automatically deleted.
- **Dedicated Repair Journal**: Operations are recorded in `<Volume>/MacBay/.operations/repair-<App>.json` (schema v1). If an operation is interrupted, `mb doctor` reports it (`incomplete_operation`) and guides you to run `mb repair "<App>" --rollback`.
- **Keep-Local**: `keep-local` removes only the item entry from `manifest.json`. Both local and external applications remain completely untouched, with the external copy becoming an unmanaged archive.


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

- **Selection Priority**: `--volume` (or `-v`) wins, then the default saved by `mb init`, then automatic detection.
- **Auto-Selection**: When exactly one eligible external volume is mounted, MacBay automatically selects it.
- **Multiple Volumes**: When two or more eligible drives are connected, `--volume <path>` (or `-v`) is required to prevent accidental writes to the wrong drive. `mb init` saves a default so the flag is not needed on every command.
- **Saved Default**: `mb init` stores one eligible volume in `~/.config/macbay/config.json` (respecting `$XDG_CONFIG_HOME`) and never silently switches to a different drive while the default is unavailable.

---

## Safety Model & Compatibility Tiers

Before migrating any bundle, `AppInspector` grades the application:

- 🟢 **Safe** (`SAFE` in JSON): Clean bundle layout with no relocation hooks or virtualization requirements. Safe for standard relocation.
- ⚠️ **Review** (`POPUP_RISK` in JSON): Application contains self-relocation checks (e.g., `moveToApplicationsFolder`, `PFMoveToApplicationsFolder` in Mach-O/ASAR) or privileged helper tools (`SMPrivilegedExecutables`). Requires the `-f, --force` flag to migrate.
- ❌ **Blocked** (`BLOCKED` in JSON): Application requires hypervisor/virtualization entitlements (`com.apple.security.virtualization`), contains Driver/System/Kernel Extensions, or has corrupted code signatures. **Migration is blocked to prevent system instability.**

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

`mb doctor --json` reports `volumes`, `findings`, `summary`, `warnings`, and `notes`. Each finding carries a stable `code` (for example `link_target_unavailable`, `link_unmanaged`, `local_data_detected`, `record_source_missing`, `manifest_unreadable`) with its `status` (`healthy`, `needs_attention`, `unable_to_verify`), related paths, sizes where relevant, and a recommended action.

`mb references --json` reports `generatedAt`, `findings`, and `notes`. Each finding carries a stable `code` (for example `external_reference_stale_candidate`, `external_reference_missing`, `external_reference_unverified`, `external_reference_scan_incomplete`, `external_config_unreadable`, `external_config_partially_checked`) with its `status`, the source file, the stored path, an optional confirmed candidate, optional `referenceLocations`, and a recommended action.

On errors, MacBay outputs a structured error envelope to `stderr` and exits with a non-zero status:

```json
{
  "error": {
    "code": "configuration_error | retryable_error | execution_error",
    "message": "Application is blocked from migration (/Applications/VirtualMachine.app)",
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
