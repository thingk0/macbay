# MacBay 1.10.0 stabilization validation

Validated on 2026-11-07 with Swift 6.4.2 and the macOS 27.2 SDK. The application retains a macOS 13.0 deployment target.

## Implemented behavior

- Developer Data now supports selected Xcode storage changes through Review → Confirm → Execute → Results. DeviceSupport and Archives moves are selected by default. DerivedData has one Keep, Move, or Remove choice. Cache and unavailable-simulator removal are off by default and require a separate acknowledgment.
- Execution revalidates the reviewed paths, physical drive identity, space, process state, and exact simulator IDs under the shared volume lock. Results retain completed actions and failures. New Xcode moves have manifest entries and interruption journals and can be restored with `mb unmove <original-path>`.
- A reproduced partial-backup-removal failure no longer rolls an incomplete backup over working data or removes the complete external copy. Recovery exposes all remaining paths. Journals survive cleanup or manifest failures. Automatic Doctor cleanup refuses paths resolving outside the current volume's MacBay Data/Xcode roots, including redirected parents.
- Default-drive saving is opt-in. Disconnecting or clearing a destination does not select another drive automatically. Setup saving and file operations share interruption guards; main-window sheets cannot overlap, and separate Preferences remains usable. Cache results include skipped paths without suggesting unrelated recovery.

## Verification

- Swift: **719 passing tests** — MacBayKit 509, MacBayTUI 135, MacBayGUI 75. The safe-runner exclusions omit 14 legacy CLI tests that discover physical drives.
- Packaging: **6 passing tests**.
- Failure fixtures cover copy/verification/link/rollback failures, partial backup deletion, failed journal/manifest writes, stale plans, unavailable/replaced/read-only drives, open files, redirected cleanup paths, exact simulator selection, and restoration of newly moved Xcode data.
- Native AppKit window QA covers light/dark Developer Data, the 800 × 580 minimum, setup/review/result sheets within the visible screen, native sidebar frame transitions, and accessible review paths and removal acknowledgments. Offscreen raster captures do not fully reproduce AppKit materials; accessibility inspection confirms the actual review content.
- The Release app reports 1.10.0, links against SDK 27.2 with minimum 13.0, passes code-signature verification, and packages into a checksum-verified local DMG.
- Developer ID signing, hardened runtime, secure timestamp, and strict signature verification pass on an isolated copy of the Release app. No private key was exported.

Filesystem mutations during testing use disposable fixtures. No real applications, Xcode data, caches, or simulators were migrated or removed. Older supported macOS versions still need runtime testing on those systems.

## Distribution status

The default `.build/gui/MacBay.app` and `MacBay-1.10.0-arm64-local.dmg` remain local ad-hoc artifacts. The separately signed verification copy is not notarized. Public release still requires the notarized distribution pipeline and a quarantined clean-install/Gatekeeper check; see [release setup](releasing-1.10.md). No release or tag was published by this stabilization work.
