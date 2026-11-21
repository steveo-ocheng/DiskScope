# DiskScope

A fast, native macOS disk-usage browser — like `ncdu`, with a Finder-style interface.

- Pick any drive (internal, external, network) or folder from the sidebar
- Finder-style column and list views with sizes and usage bars, back/forward, path bar, search
- Parallel scanner (readdir + fstatat, never follows symlinks, hard links counted once); matches `du`
- Disk usage vs. apparent size, rescan a folder, move to Trash (with safety checks), show in Finder

Requires macOS 14+. Built with SwiftPM and the Command Line Tools — no Xcode project.

## Build

```sh
./build-app.sh            # build/DiskScope.app (universal, Hardened Runtime, ad-hoc signed)
./build-app.sh --install  # also copy to /Applications
./build-app.sh --dmg      # also make build/DiskScope-<version>.dmg
```

Run the tests (swift-testing, prints coverage): `Tests/run-tests.sh`

For distribution to other Macs, sign with a Developer ID and notarize:

```sh
SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=<profile> ./build-app.sh --dmg
```

For complete results in protected folders (Mail, Messages…), grant DiskScope Full Disk Access in
System Settings › Privacy & Security.

## Security & privacy

- **Read-only scanning, no network.** The app reads file metadata only (`readdir` + `fstatat`); it never
  reads file contents, has no networking code, and collects nothing.
- **Never follows symlinks.** Entries are `lstat`-ed relative to their directory's descriptor, and each
  subdirectory is checked (device + inode) after opening, so a folder swapped for a symlink mid-scan
  can't redirect the scan elsewhere. Names that aren't valid UTF-8 are flagged, not traversed.
- **Move to Trash is guarded.** System paths, top-level and home folders and whole volumes are refused.
  Right before moving, each item is re-verified: the enclosing folders must still be the same real path
  (scan roots are canonicalized with `realpath`), and the item must be the same kind — and for files the
  same size and modification time — as when scanned. The confirmation lists full paths with
  control/bidi characters made visible. Items go to the Trash (recoverable), never deleted.
- **No implicit launching.** Double-clicking an app, script, installer or executable reveals it in Finder
  instead of running it; opening it requires an explicit menu choice.
- **Hardened Runtime, no entitlements.** Not sandboxed by design: measuring a whole disk needs access the
  App Sandbox doesn't allow. Distribute with a Developer ID signature and notarization (see above).

## License

MIT — see [LICENSE](LICENSE).
