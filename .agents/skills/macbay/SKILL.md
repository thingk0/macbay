---
name: macbay
description: Use MacBay to inspect and safely externalize macOS applications, Xcode data, and developer caches.
---

# MacBay Agent Skill

Use the `mb` CLI (or its alias `macbay`) for storage-aware Mac maintenance. Prefer `--json` when consuming results programmatically.

## Safety rules

1. **Check Dashboard & Warnings**: Start with `mb status --json`. Verify `externalVolumes` and inspect any excluded volumes in `warnings` (installer DMGs, non-APFS drives, etc.). If more than one eligible volume is mounted, `--volume` is strictly required.
2. **Inspect App Compatibility**: Run `mb scan --json` (or `mb scan`). App candidates are graded:
   - 🟢 **SAFE**: Safe to dock.
   - ⚠️ **POPUP_RISK**: Contains relocation signals or privileged helper tools. Never dock without informing the user and providing the `--force` flag.
   - ❌ **BLOCKED**: Has hypervisor/virtualization entitlements, kernel/system/driver extensions, or corrupted bundles. Never attempt to dock a blocked app.
3. **Always Dry-Run First**: Use `--dry-run` before any mutating command (`dock`, `undock`, `xcode`, `cache`). Note: `status` and `scan` are read-only and do not accept `--dry-run` or `--yes`.
4. **Locks & Process Safety**: Do not bypass process or SQLite lock errors. Ask the user to quit the reported process and retry.
5. **Confirmation Prompts**: Preserve user confirmation prompts unless the user explicitly requested unattended execution with `--yes`.
6. **Structured Errors**: In `--json` mode, failures output a standard JSON error envelope to `stderr` with a non-zero exit code:
   ```json
   {
     "error": {
       "code": "configuration_error | retryable_error | execution_error",
       "message": "...",
       "details": "..."
     }
   }
   ```

## Common workflows

```sh
# 1. Status & Scan
mb status --json
mb scan --json

# 2. Docking applications
mb dock <AppName>.app --dry-run
# If popupRisk:
mb dock <AppName>.app --force --dry-run
# Real run:
mb dock <AppName>.app

# 3. Xcode DeviceSupport & Simulator cleanup
mb xcode --dry-run
mb xcode

# 4. Developer caches (npm, uv, Gradle, HF)
mb cache --enable --dry-run
mb cache --enable
mb cache --reset
```

Explain the planned source, destination, size, and any safety warnings before running a mutating command. Never claim a migration succeeded unless the CLI exits successfully.

