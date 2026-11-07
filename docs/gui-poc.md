# macOS GUI — 1.10.0

The English SwiftUI desktop application is MacBay's primary interface on macOS 13 and later.
It shares `MacBayKit` with the CLI and has no dependency on `MacBayTUI`.

## Run and package

From the repository root:

```sh
bash scripts/run-app.sh --demo

# Live storage
bash scripts/run-app.sh

# Live storage and an optional local DMG
bash scripts/build-app.sh --dmg
open .build/gui/MacBay.app
```

`--demo` uses deterministic sample data and does not scan the host filesystem.
Without it, the app reads disk status, applications, diagnostics, and MacBay history.
`run-app.sh` builds the packaged Debug app and opens that exact bundle. Quit an already
open MacBay before rebuilding or switching demo mode. Use `--release` for a Release build.
The script explicitly links against the selected Xcode SDK while retaining the macOS 13
minimum, then checks the binary's `LC_BUILD_VERSION` before packaging. Some SwiftPM
backends otherwise record the deployment version as the SDK, which makes AppKit use
compatibility styling even on a new OS. Use the packaged app for appearance reviews;
plain `swift run MacBayApp` can use compatibility styling with some toolchains.
Use `run-app.sh` when checking the window design.

The packaging script creates:

- `.build/gui/MacBay.app`: a self-contained app with its resource bundle and existing MacBay icon.
- `.build/gui/MacBay-1.10.0-arm64-local.dmg`: a disk image containing the app and an Applications shortcut.
- A matching `.sha256` checksum; `MacBay-PoC.dmg` remains a compatibility symlink.

These artifacts use local ad-hoc signing. They are not notarized release downloads.
Public distribution needs Developer ID signing, hardened runtime configuration,
and Apple notarization. Staple the ticket for reliable offline Gatekeeper checks.
No certificates or release credentials are needed for local builds.
See [release setup](releasing-1.10.md) for credential names and the distribution pipeline.

## Window design

The main window uses an AppKit full-height sidebar and native sidebar animation.
A standard toolbar contains back/forward navigation, the current page title, the sidebar
toggle, and Refresh. Sidebar selections and links inside pages share navigation history.
Storage, Developer Data, Cleanup, Update Center, Recovery, Diagnostics, and History use
native grouped forms, following System Settings spacing and section backgrounds.
Applications retains its native table and details panel. Light/dark appearances follow
the system or the user's existing appearance setting. Reduce Motion is respected.
The default content size is 900 × 700, with an 800 × 580 minimum.

## Desktop scope

- **Overview**: real internal/external capacity, drive selection, candidate app sizes, warnings, and recent history.
- **Menu bar**: connected internal/external gauges with used percentages by default. Choose Combined storage or Available space in Settings or the popover; preferences persist across launches. The external gauge follows the same selected destination as Overview. The popover shows each disk and their combined available space. Combined percentage is weighted by disk capacity and includes only the selected connected external drive. Disconnected, unselected, loading, and unreadable disks never retain stale external capacity.
- **Applications**: native table, search, local/external filters, compatibility status, app details, and confirmed single-app moves and restores. Finder and copy-path actions are available from app details and the context menu; Command-F focuses search.
- **Developer Data**: discovered and managed data plus confirmed Xcode storage execution. DeviceSupport and Archives moves are selected by default. DerivedData has mutually exclusive Keep, Move, and Remove choices. Cache and unavailable-simulator removal are off by default and require their own acknowledgment. Review shows source/destination paths, copy size, free space, cleanup locations, and exact simulator IDs. Empty plans explain why execution is disabled.
- **Cleanup**: shared cache whitelist, explicit selection, running-app exclusion, preview, and a separate acknowledgment before permanent removal. Results retain skipped paths and individual failures.
- **Update Center**: persisted update workflows, manual Prepare → vendor update → Finish, and supported managed Kiro CLI updates.
- **Recovery Center**: grouped interrupted repairs, updates, adoptions, moves, and restores; confirmed repair rollback and update resume/finish actions, with manual CLI guidance for other states.
- **Diagnostics**: shared doctor findings and exact recommended next actions.
- **History**: existing CLI operation records, including partial and failed results.
- **Setup**: choose an external drive, check APFS identity, free space, application/cache access, and run the first diagnosis. Saving the selected drive as the default requires an explicit toggle; skipping setup does not change configuration.
- **Settings**: a separate native window with system/light/dark appearance, compact rows, the app details panel, menu-bar visibility/display/values, and opt-in completion notifications.
- **MacBay updates**: a manual stable-release check opens the official release page when a newer version is available. It does not download or install automatically.

Xcode Storage, Applications, Cleanup, Update Center, and supported Recovery Center
actions use a separate preview and explicit confirmation.
Default-drive saving is opt-in. Losing or clearing a selected destination never silently
switches a pending action to another connected drive. Only one main-window sheet is presented
at a time; Settings remains a separate window.

Preparing an app for update restores it locally;
finishing returns it to its original physical drive. Vendor updating is manual except
for the existing supported Kiro CLI managed updater. Finishing requires acknowledgment
that the vendor update is complete and the app is closed. Compatibility warnings need
a separate acknowledgment before the shared engine receives its existing force option.
Cache removal additionally requires acknowledging that deleted caches cannot be restored.
Previews never add operation history entries; executed actions use the existing engine history.
Reported cache sizes are logical bytes and do not guarantee the same increase in APFS free space.

Recovery Center validates repair journals rather than inventing a generic rollback.
Adoption, move, restore, unknown, and ambiguous states show read-only guidance and
the supported CLI dry run when known. The GUI never executes a displayed command string.
Demo workflows are simulated in memory and never mutate host applications or updater settings.

Only eligible external APFS drives appear as move destinations. Several drives
require an explicit choice unless a configured default is connected. A missing
configured default never silently selects another drive. Restoring an app uses
its actual external link and record, independently of the move destination picker.

Disk changes refresh status without starting any operation. Changing the app,
drive, cache selection, or screen discards an in-flight preview. Failed
diagnostics stay unknown instead of being displayed as healthy.

The menu bar and Overview share one status snapshot. A lightweight capacity-only read
runs every 30 seconds, when the popover opens, and after wake; it does not rescan apps,
run Diagnostics, or discard an unchanged reviewed preview. Reads pause during execution
and the existing completion refresh updates both surfaces. Closing the window keeps
MacBay running while menu-bar display is enabled; Open MacBay reopens it and Quit MacBay
exits explicitly. Disable menu-bar display to retain the window-only lifecycle.

## Native macOS appearance

The main window is owned by `NSSplitViewController` with a native sidebar item and a
SwiftUI content item. AppKit owns the sidebar material, rounded edges, tracking
separator, and animated toggle. The toolbar uses the system sidebar button. System colors, semantic text styles, grouped Form sections, table rows,
resizable split panes, and standard bordered buttons keep the interface consistent
with macOS. The system supplies materials and accessibility behavior. No custom glass layers,
content gradients, floating sidebar shell, or rounded table container are added.
On macOS 26+, the content item adopts AppKit's safe-area adjustment so the system
sidebar can float above the content. The older sidebar material is hidden inside
the SwiftUI list so it does not cover the system material.
The selected system accent color is used for ordinary controls and storage gauges.

Settings opens in its own reusable native window through Settings… or Command-Comma.
The grouped form separates General, Menu Bar, Notifications, and MacBay. Setup and
release-check actions bring the main window forward before presenting their workflow.
Search uses NSSearchField, including its standard clear button and Command-F focus.

The menu-bar popover retains the connected gauges, per-drive usage, and combined
available space. Display and value choices, Settings, and Quit are in its native
Options menu. The status item observes only storage data and relevant preferences;
workflow progress does not redraw its gauges.

Standard controls adapt to macOS appearance and accessibility preferences, including
light/dark appearance and Reduce Transparency. The sidebar uses AppKit's built-in collapse/reveal transition and immediately updates
when Reduce Motion is enabled. The menu-bar progress indicator also respects Reduce
Motion. A guarded AppKit safe-area API supports the modern layout while retaining
macOS 13 compatibility.

## Architecture and validation

`MacBayApp` owns the AppKit application lifecycle and a native split controller at
the window root. The sidebar and main content are hosted separately in SwiftUI;
the detail controller stays alive while the sidebar collapses. Native collapse state
and the store's sidebar visibility stay synchronized, including repeated toggles. `MacBayGUI` contains SwiftUI
views, a main-actor store, and an asynchronous service boundary. `LiveGUIService`
serializes the synchronous core reads on its own actor so scanning does not block
the UI, including during file operations. `DemoGUIService` supplies sample data
and simulated actions to the same views.

`ApplicationMigrationPlan` captures the move or restore dry run, physical volume UUID,
and bounded path fingerprints. `CachePurgePlan` refreshes the whitelist and running-app
checks and fingerprints every selected path. `DefaultVolumePlan` retains the previous
configuration and selected volume identity. Execution rechecks each plan before mutation.

`XcodeStoragePlan` captures the exact selected actions, physical drive identity, source and
destination fingerprints, cleanup scope, Xcode process state, and unavailable simulator IDs.
Execution holds the shared volume lock while revalidating the plan and applying changes.
No GUI force override is offered. Simulator tools are not queried when simulator cleanup is off.
Moved Xcode folders have manifest entries and interruption journals, and can be restored with
`mb unmove <original-path>`. The GUI shows managed folders; interrupted moves expose their
source, destination, and backup in Recovery Center for manual inspection.
If old-backup cleanup fails, the original-path link and complete destination stay intact.
Doctor preserves journals when a backup remains or safe reconciliation cannot be established.
Cleanup results list skipped paths and failures; disposable-cache failures do not offer an unrelated recovery action.

`AppUpdatePlan` captures a shared-engine dry run, the persisted workflow, resolved
original volume, and bounded filesystem fingerprints. Execution reruns the shared
preflight and rejects changed conditions. `RepairRollbackPlan` validates the existing
repair layout, phase, app signatures and identities, volume UUID, and all affected
paths, including staging parent contents. It refuses automatic cleanup when the
staging parent contains unrelated data. Rollback revalidates the reviewed journal
and plan under the existing volume operation lock. Partial rollback keeps the journal
and remaining staging data and reports failure.

The GUI keeps prepared plans behind single-use preview tokens. Navigation, refresh,
disk changes, and cancellation invalidate pending confirmation; late previews are
discarded. Every execution result refreshes workflow state, Diagnostics, and History.
Progress callbacks are scoped to one execution. The window has a minimum content size
of 800 × 580, and closing or quitting is blocked while files or the default-drive setting are being changed.

`GUIAssets` explicitly resolves the bundled resources in a packaged `.app`, with
the SwiftPM module bundle as the development fallback. This handles the different
resource lookup code generated by SwiftPM 5.x and Swift Build 6.x.

```sh
swift build --product MacBayApp
bash scripts/test-safe.sh
python3 -m unittest discover -s Tests/PackagingTests -v
```

GUI tests use in-memory services and temporary journal fixtures. They cover confirmation,
cancellation, stale results, failure and retry, native sidebar state/transition round trips, demo isolation, supported/ambiguous journal
classification, and operation-specific manual guidance. Core workflow tests use temporary
applications and mock APFS volumes to cover signatures, running processes, changed records
and files, missing/replaced volumes, redirected parents, partial rollback, cleanup
failures, setup choices, and mocked release checks. The safe runner excludes legacy
CLI fixtures that require a physical external drive.
Tests never relocate real apps or write to a physical external drive.
See [1.10 stabilization validation](validation-1.10.md) for the verified scope and remaining distribution checks.
