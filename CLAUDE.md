# DiskScope

Native macOS (SwiftUI, macOS 14+) disk-usage browser, like ncdu, with a Finder-style UI. SwiftPM package; no Xcode project (only Command Line Tools are installed).

## Build / run
- `./build-app.sh` → `build/DiskScope.app` (universal arm64+x86_64, Hardened Runtime, ad-hoc signed).
  `--install` copies to /Applications, `--dmg` makes a DMG. `SIGN_IDENTITY=` / `NOTARY_PROFILE=` for Developer ID + notarization.
- Per-arch builds use `.build/arm64` and `.build/x86_64` scratch paths (XCBuild isn't available, so `--arch a --arch b` fails; script uses `--triple` + `lipo`).
- A folder path argument starts a scan on launch: `open build/DiskScope.app --args ~/dir`.
- `swift scripts/make-icon.swift` regenerates `Resources/AppIcon.icns`.
- Tests: `Tests/run-tests.sh` (swift-testing, ~3 s, prints coverage; `--filter X` for a subset). Works with plain Command Line Tools (script adds the Testing.framework search path + `-disable-cross-import-overlays`). Model tests must inject a fake `AppModel(trasher:)` — never touch the real Trash.

## Layout (Sources/DiskScope)
- `Scanner.swift` — parallel walker (worker threads, readdir + fstatat relative to dir fd, never follows symlinks; each opened subdir is checked against the (dev, ino) seen when listed; non-UTF-8 names flagged, not traversed). Disk size = st_blocks*512; hard links counted once. Skips `/System/Volumes/Data`, `/Volumes`, `/dev` below the root. `scan(...)` throws on unreadable root, returns nil on cancel.
- `FileNode.swift` — tree node; dirs hold aggregated totals. **`parent` is `unowned`**: never retain a node whose ancestors may be freed. Anything that drops a subtree must first call `AppModel.purgeReferences(into:)`.
- `AppModel.swift` — @MainActor state: scan/rescan (subtree splice), back/forward history, cached sorting (`sortedChildren`), search, Trash (`TrashGuard`: blocks system paths and unreliable items; before moving re-verifies realpath of parent, kind, and file size/mtime). Scan roots are canonicalized with realpath. `LaunchSafety` stops double-click from launching apps/scripts.
- `Volumes.swift` — mounted volumes + `VolumeStore` (refreshes on mount/unmount).
- UI: `ContentView.swift` (split view, toolbar, welcome, scanning), `Sidebar.swift` (Locations/Favorites), `ColumnBrowser.swift` (Finder column view), `ListBrowser.swift` (table + search results), `Components.swift` (icons, bars, path/status bars, preview).
