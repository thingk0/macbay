---
name: macbay
description: Use MacBay to inspect and safely externalize macOS applications, Xcode data, and developer caches.
---

# MacBay Agent Skill

Use the `mb` CLI (or its alias `macbay`) for storage-aware Mac maintenance. Prefer `--json` when consuming results programmatically.

## Safety rules

1. **Check Dashboard & Warnings**: Start with `mb status --json`. Verify `externalVolumes` and inspect any excluded volumes in `warnings` (installer DMGs, non-APFS drives, etc.). If more than one eligible volume is mounted, `--volume` is strictly required.
2. **Verify Links & Records**: Run `mb doctor --json` before mutating anything. It is read-only and reports `findings` grouped as `healthy`, `needs_attention`, and `unable_to_verify` with stable `code` values (for example `link_target_unavailable`, `link_record_mismatch`, `record_target_missing`, `record_source_missing`, `local_data_detected`, `manifest_unreadable`, `incomplete_operation`) plus a recommended action per finding. `incomplete_operation` indicates an interrupted `adopt` or `repair` operation that left a journal on the volume; roll it back with `mb repair "<App>.app" --rollback` or the reported rollback command. `local_data_detected` means a recorded source path is a regular file or directory again while the recorded copy still exists — use `mb repair "<App>.app"` to safely inspect and compare both copies. Exit codes: `0` healthy, `1` problems or unverifiable items, `2` the check itself failed. Never treat a nonzero `doctor` result as something to force past — report the finding to the user, and never claim a missing target was ejected or deleted.
3. **Inspect App Compatibility**: Run `mb scan --json` (or `mb scan`). App candidates are graded:
   - 🟢 **SAFE**: Safe to dock.
   - ⚠️ **POPUP_RISK**: Contains relocation signals or privileged helper tools. Never dock or adopt without informing the user and providing the `--force` flag.
   - ❌ **BLOCKED**: Has hypervisor/virtualization entitlements, kernel/system/driver extensions, or corrupted bundles. Never attempt to dock or adopt a blocked app.
4. **Always Dry-Run First**: Use `--dry-run` before any mutating command (`dock`, `undock`, `adopt`, `repair`, `xcode`, `cache`). The preview for `dock` and `undock` includes source size, destination free space, estimated free space after the copy, expected internal space freed, and any shortfall. For `adopt`, it previews same-volume relocation to MacBay standard layout and symlink updates with 0 additional space required. For `repair`, it previews backup paths, space impact, and manifest updates. Report those numbers to the user. Note: `status`, `scan`, and `doctor` are read-only and do not accept `--dry-run` or `--yes`.
5. **Space Safety**: Real runs re-check free space and abort with `insufficient_space` (retryable) or `space_check_failed` (execution) before copying or replacing anything. Never work around these errors — ask the user to free space or reconnect the volume, and never claim a migration will succeed just because the dry-run estimate was sufficient.
6. **Locks & Process Safety**: Do not bypass process or SQLite lock errors. Ask the user to quit the reported process and retry.
7. **Unmanaged External Links**: If an application in `/Applications` is already an unmanaged symlink to an external volume, `mb dock` will reject it and suggest `mb adopt`. Use `mb adopt <AppName>.app` to adopt it into the standard MacBay layout and manifest without copying back to the internal disk first.
8. **Duplicate App Repair (`repair`)**: When `doctor` reports `local_data_detected`, use `mb repair <AppName>.app` for read-only side-by-side comparison (version, build, identifier, signature, size). Use `--action redock` to re-externalize the local bundle into MacBay layout, which archives the previous external copy to `<Volume>/MacBay/Backups/<OpID>/<App>.app` (backups are never automatically deleted). Use `--action keep-local` to retain the local app in `/Applications` and atomically remove its manifest record, leaving the external copy untouched as an unmanaged archive. If an operation is interrupted, roll it back with `mb repair <AppName>.app --rollback`.
9. **Confirmation Prompts**: Preserve user confirmation prompts unless the user explicitly requested unattended execution with `--yes`.
10. **Structured Errors**: In `--json` mode, failures output a standard JSON error envelope to `stderr` with a non-zero exit code:
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

# 3. Adopting already-externalized unmanaged applications
mb adopt <AppName>.app --dry-run
mb adopt <AppName>.app

# 4. Undocking / Restoring applications
mb undock <AppName>.app --dry-run
mb undock <AppName>.app

# 5. Duplicate App Repair (local_data_detected)
mb repair <AppName>.app --json
mb repair <AppName>.app --action redock --dry-run
mb repair <AppName>.app --action keep-local --dry-run
mb repair <AppName>.app --action redock
mb repair <AppName>.app --action keep-local
mb repair <AppName>.app --rollback

# 6. Xcode DeviceSupport & Simulator cleanup
mb xcode --dry-run
mb xcode

# 7. Developer caches (npm, uv, Gradle, HF)
mb cache --enable --dry-run
mb cache --enable
mb cache --reset
```

Explain the planned source, destination, size, and any safety warnings before running a mutating command. Never claim a migration succeeded unless the CLI exits successfully. When `mb doctor` reports `needs_attention` or `unable_to_verify`, describe the reported paths and suggested action to the user; do not delete, overwrite, or re-move anything on their behalf.

