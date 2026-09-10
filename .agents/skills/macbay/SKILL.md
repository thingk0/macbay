---
name: macbay
description: Use MacBay to inspect and safely externalize macOS applications, Xcode data, and developer caches.
---

# MacBay Agent Skill

Use the `mb` CLI (or its alias `macbay`) for storage-aware Mac maintenance. Prefer `--json` when consuming results programmatically.

## Safety rules

1. **Check Dashboard & Warnings**: Start with `mb status --json`. Verify `externalVolumes` and inspect any excluded volumes in `warnings` (installer DMGs, non-APFS drives, etc.). If more than one eligible volume is mounted, `--volume` is strictly required.
2. **Verify Links & Records**: Run `mb doctor --json` before mutating anything. It is read-only and reports `findings` grouped as `healthy`, `needs_attention`, and `unable_to_verify` with stable `code` values (for example `link_target_unavailable`, `link_record_mismatch`, `record_target_missing`, `manifest_unreadable`) plus a recommended action per finding. Exit codes: `0` healthy, `1` problems or unverifiable items, `2` the check itself failed. Never treat a nonzero `doctor` result as something to force past — report the finding to the user, and never claim a missing target was ejected or deleted.
3. **Inspect App Compatibility**: Run `mb scan --json` (or `mb scan`). App candidates are graded:
   - 🟢 **SAFE**: Safe to dock.
   - ⚠️ **POPUP_RISK**: Contains relocation signals or privileged helper tools. Never dock without informing the user and providing the `--force` flag.
   - ❌ **BLOCKED**: Has hypervisor/virtualization entitlements, kernel/system/driver extensions, or corrupted bundles. Never attempt to dock a blocked app.
4. **Always Dry-Run First**: Use `--dry-run` before any mutating command (`dock`, `undock`, `xcode`, `cache`). The preview for `dock` and `undock` includes source size, destination free space, estimated free space after the copy, expected internal space freed, and any shortfall. Report those numbers to the user. Note: `status`, `scan`, and `doctor` are read-only and do not accept `--dry-run` or `--yes`.
5. **Space Safety**: Real runs re-check free space and abort with `insufficient_space` (retryable) or `space_check_failed` (execution) before copying or replacing anything. Never work around these errors — ask the user to free space or reconnect the volume, and never claim a migration will succeed just because the dry-run estimate was sufficient.
6. **Locks & Process Safety**: Do not bypass process or SQLite lock errors. Ask the user to quit the reported process and retry.
7. **Confirmation Prompts**: Preserve user confirmation prompts unless the user explicitly requested unattended execution with `--yes`.
8. **Structured Errors**: In `--json` mode, failures output a standard JSON error envelope to `stderr` with a non-zero exit code:
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
# 1. Status, Scan & Diagnosis
mb status --json
mb doctor --json
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

Explain the planned source, destination, size, and any safety warnings before running a mutating command. Never claim a migration succeeded unless the CLI exits successfully. When `mb doctor` reports `needs_attention` or `unable_to_verify`, describe the reported paths and suggested action to the user; do not delete, overwrite, or re-move anything on their behalf.

