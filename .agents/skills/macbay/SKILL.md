---
name: macbay
description: Use MacBay to inspect and safely externalize macOS applications, Xcode data, and developer caches.
---

# MacBay Agent Skill

Use the `mb` CLI (or its alias `macbay`) for storage-aware Mac maintenance. Prefer `--json` when consuming results programmatically.

## Safety rules

1. **Check Dashboard & Warnings**: Start with `mb status --json`. Verify `externalVolumes` and inspect any excluded volumes in `warnings` (installer DMGs, non-APFS drives, etc.). If more than one eligible volume is mounted, `--volume` is strictly required.
2. **Verify Links & Records**: Run `mb doctor --json` before mutating anything. It is read-only and reports externalization integrity only: application and developer-data symlinks, target existence, volume and manifest state, locally regrown data, and interrupted operations. Findings use `healthy`, `needs_attention`, and `unable_to_verify` with stable `code` values (for example `link_target_unavailable`, `link_record_mismatch`, `record_target_missing`, `record_source_missing`, `local_data_detected`, `manifest_unreadable`, `incomplete_operation`) plus a recommended action per finding. `incomplete_operation` indicates an interrupted `adopt` or `repair` operation that left a journal on the volume; roll it back with `mb repair "<App>.app" --rollback` or the reported rollback command. `local_data_detected` means a recorded source path is a regular file or directory again while the recorded copy still exists — use `mb repair "<App>.app"` to safely inspect and compare both copies. Conversation or execution history never affects this check. Exit codes: `0` healthy, `1` problems or unverifiable items, `2` the check itself failed. Never treat a nonzero `doctor` result as something to force past — report the finding to the user, and never claim a missing target was ejected or deleted.
3. **Inspect Stored App Paths**: `mb doctor` never scans configuration files. To check app paths stored in settings, run `mb references --path <file> [--path <file> ...] --json`. Only the specified files are read (directories are rejected, repeats are checked once); no home, hidden-folder, or plugin-cache auto-discovery runs. It reports the source file, reference location, stored path, verification result, and any confirmed candidate under `/Applications` or `~/Applications`, using the same reference finding codes (`external_reference_stale_candidate`, `external_reference_missing`, `external_reference_unverified`, `external_reference_scan_incomplete`, `external_config_unreadable`, `external_config_partially_checked`). MacBay never confirms whether a setting is currently in use — if a stored path looks wrong, confirm usage first, then back up the file and update the path; MacBay never edits those files. Exit codes: `0` clean, `1` missing paths, unreadable files, or incomplete reads, `2` bad arguments or a failed check.
4. **Inspect App Compatibility**: Run `mb scan --json` (or `mb scan`). App candidates are graded:
   - 🟢 **SAFE**: Relocation checks permit docking; this does not certify that a future vendor self-update works while the bundle is external. Apply the selection policy in README.md before recommending long-term externalization.
   - ⚠️ **POPUP_RISK**: Contains relocation signals or privileged helper tools. Never dock or adopt without informing the user and providing the `--force` flag.
   - ❌ **BLOCKED**: Has hypervisor/virtualization entitlements, kernel/system/driver extensions, or corrupted bundles. Never attempt to dock or adopt a blocked app.
5. **Always Dry-Run First**: Use `--dry-run` before any mutating command that supports it (`dock`, `undock`, `adopt`, `repair`, `update begin`, `update finish`, `update run`, `recover`, `move`, `unmove`, `xcode`, `cache`, `purge`, and `update schedule enable`). The preview for `dock` and `undock` includes source size, destination free space, estimated free space after the copy, expected internal space freed, and any shortfall. For `adopt`, it previews same-volume relocation to MacBay standard layout and symlink updates with 0 additional space required. For `repair`, it previews backup paths, space impact, and manifest updates. For `purge`, it scans whitelisted caches and previews recoverable space without modifying files. Report those numbers to the user. Note: `status`, `scan`, `doctor`, and `update status` are read-only and do not accept `--dry-run` or `--yes`.
6. **Space Safety**: Real runs re-check free space and abort with `insufficient_space` (retryable) or `space_check_failed` (execution) before copying or replacing anything. Never work around these errors — ask the user to free space or reconnect the volume, and never claim a migration will succeed just because the dry-run estimate was sufficient.
7. **Locks & Process Safety**: Do not bypass process or SQLite lock errors. Ask the user to quit the reported process and retry.
8. **Unmanaged External Links**: If an application in `/Applications` is already an unmanaged symlink to an external volume, `mb dock` will reject it and suggest `mb adopt`. Use `mb adopt <AppName>.app` to adopt it into the standard MacBay layout and manifest without copying back to the internal disk first.
9. **Duplicate App Repair (`repair`)**: When `doctor` reports `local_data_detected`, use `mb repair <AppName>.app` for read-only side-by-side comparison (version, build, identifier, signature, size). Use `--action redock` to re-externalize the local bundle into MacBay layout, which archives the previous external copy to `<Volume>/MacBay/Backups/<OpID>/<App>.app` (backups are never automatically deleted). Use `--action keep-local` to retain the local app in `/Applications` and atomically remove its manifest record, leaving the external copy untouched as an unmanaged archive. If an operation is interrupted, roll it back with `mb repair <AppName>.app --rollback`.
10. **External App Updates (update)**: Prefer large supported data stores for SSD savings. For app bundles, distinguish relocation safety from update safety. Use `mb update run "Kiro CLI.app" --dry-run` and then `mb update run "Kiro CLI.app"` for Kiro; it disables and verifies background updates, runs the official updater, verifies the result, and returns the app to its original volume. Other apps can use `mb update begin`/`finish`. Failed checks preserve the local app and workflow for retry. `mb update schedule` is optional and off by default; enable it only after the installed `mb` binary is at a stable path. Never bypass signature or identity failures. If an uncontrolled self-updater has broken an external bundle, keep that app internal until a controlled route is verified.
11. **Application Cache Purging (`purge`)**: Use `mb purge` (`mb pu`) to safely reclaim disk space from disposable caches without moving folders. It strictly matches whitelisted folders (`CacheStorage`, `Code Cache`, `GPUCache`, `GPUPersistentCache`, `DawnCache`, `blob_storage`, `ShipIt`, `Homebrew`) and never touches SQLite databases, user accounts, sessions, or preferences. By default, running applications are skipped unless `--include-running` is passed.
12. **Missing Recorded App Recovery (`recover`)**: If `doctor` finds a recorded application link whose external target is missing, use `mb recover <App>.app --from <candidate> --expected-bundle-id <ID> --expected-team-id <ID> --dry-run`. Only use a candidate verified as belonging to the expected publisher. Recovery copies and verifies it under `/Applications` before removing the stale manifest record; preserve the candidate and never bypass signature or identity checks. `purge` skips a matching ShipIt installer that `doctor` identifies as a recovery candidate.
13. **Kiro Session Data**: Keep `~/.kiro` settings and credentials internal. Only consider moving `~/.kiro/sessions` after a dry run, and verify old session resume and new session writes. Restore with `mb unmove ~/.kiro/sessions` if either check fails.
14. **Confirmation Prompts**: Preserve user confirmation prompts unless the user explicitly requested unattended execution with `--yes`.
13. **Structured Errors**: In `--json` mode, failures output a standard JSON error envelope to `stderr` with a non-zero exit code:
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

`mb references` reads JSON, plist, TOML, YAML, INI, and shell-like files passed with `--path` (relative paths use the current directory; `~` uses the home directory). Limits: 10,000 configuration files, 2 MiB per file, 64 MiB total. Heuristic extraction of path-like strings is supported; MacBay does not expand variables, execute scripts, or edit those files. There is no TUI entry point for this check.

```sh
# 1. Status, Scan & Diagnosis
mb status --json
mb doctor --json
mb references --json --path ~/.cursor/mcp.json
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

# 5. Updating an externalized application
mb update run "Kiro CLI.app" --dry-run
mb update run "Kiro CLI.app"
mb update status
# Optional schedule, off by default; use only with an installed stable mb path.
mb update schedule status
mb update schedule enable --dry-run
mb update schedule enable
mb update schedule disable
# For other apps: begin, run their vendor updater, then finish.
mb update begin <AppName>.app --dry-run
mb update begin <AppName>.app
mb update finish <AppName>.app --dry-run
mb update finish <AppName>.app

# 6. Recover a missing recorded app target
mb recover <AppName>.app --from <candidate.app> --expected-bundle-id <ID> --expected-team-id <ID> --dry-run
mb recover <AppName>.app --from <candidate.app> --expected-bundle-id <ID> --expected-team-id <ID>

# 7. Duplicate App Repair (local_data_detected)
mb repair <AppName>.app --json
mb repair <AppName>.app --action redock --dry-run
mb repair <AppName>.app --action keep-local --dry-run
mb repair <AppName>.app --action redock
mb repair <AppName>.app --action keep-local
mb repair <AppName>.app --rollback

# 8. Move Kiro session history only (keep credentials/settings internal)
mb move ~/.kiro/sessions --dry-run
mb move ~/.kiro/sessions
mb unmove ~/.kiro/sessions --dry-run

# 9. Xcode Storage Externalization & Cache Purge
mb xcode --dry-run
mb xcode
mb xcode --clean-derived-data --dry-run
mb xcode --clean-caches --dry-run
mb xcode --all --dry-run

# 10. Developer caches (npm, uv, Gradle, HF)
mb cache --enable --dry-run
mb cache --enable
mb cache --reset

# 11. Lossless Application Cache Purging (Chromium, Electron, Homebrew)
mb purge --dry-run
mb purge --dry-run --json
mb purge --app Slack
mb purge --include-running
mb purge --yes
```

Explain the planned source, destination, size, and any safety warnings before running a mutating command. Never claim a migration succeeded unless the CLI exits successfully. When `mb doctor` reports `needs_attention` or `unable_to_verify`, describe the reported paths and suggested action to the user; do not delete, overwrite, or re-move anything on their behalf.

