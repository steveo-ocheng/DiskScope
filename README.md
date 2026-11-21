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

For distribution to other Macs, sign with a Developer ID and notarize:

```sh
SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=<profile> ./build-app.sh --dmg
```

For complete results in protected folders (Mail, Messages…), grant DiskScope Full Disk Access in
System Settings › Privacy & Security.
