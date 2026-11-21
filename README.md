# DiskScope

[![CI](https://github.com/steveo-ocheng/DiskScope/actions/workflows/ci.yml/badge.svg)](https://github.com/steveo-ocheng/DiskScope/actions/workflows/ci.yml)

A fast, native macOS disk-usage browser — like `ncdu`, with a Finder-style interface.

- Pick any drive (internal, external, network) or folder from the sidebar
- Finder-style column and list views with sizes and usage bars, back/forward, path bar, search
- **Sunburst view** (⌘4): a ring chart of the current folder, one ring per folder level, slices sized by
  usage. Hover for details, click a slice to drill in, click the center to go up, with a "Largest items" legend
- **"Not in scan"**: for whole-disk scans, shows the used space the scan couldn't see and why — other APFS
  volumes on the same disk (VM swap, Preboot, Recovery…), Time Machine local snapshots, unreadable folders and
  system data, with purgeable space noted. In the status bar, and as a gray slice in the sunburst
- **Find Duplicates**: pick a folder, optionally a second one to compare against. Files are matched by size,
  then SHA-256 checksum. Compare two copies side by side — text, images, video/audio (Play Both), PDF, or a
  Quick Look thumbnail
- **Removal script you review**: Find Duplicates never deletes or moves anything itself. Mark copies Keep or
  Remove (or use a rule: keep the copy in Folder A / Folder B / the oldest / the newest / the shortest path —
  every set always keeps at least one copy), then **Removal Script…** saves a bash script to read and run in
  Terminal: `bash remove-duplicates.sh` is a dry run, `bash remove-duplicates.sh --apply` moves the marked files
  to the Trash, re-checking with `shasum -a 256` before each move that the file and the kept copy are still
  identical (anything that changed is skipped). The script is saved non-executable
- **Export CSV**: the current folder or whole scan (path, kind, size on disk, apparent size, items, modified), or
  the duplicate sets (set, SHA-256, size, copies, wasted, side, keep/remove, path, modified). Fields a spreadsheet
  could run as formulas are neutralised
- **Ask Claude** (optional, off by default): a panel on the right of the browser for questions about the scan —
  "What's using the most space?", "What can I safely delete?" — using your own Anthropic API key (see
  [Getting an API key](#getting-an-api-key-for-ask-claude) and [Security & privacy](#security--privacy) for exactly
  what's sent)
- Parallel scanner (readdir + fstatat, never follows symlinks, hard links counted once); matches `du`
- Disk usage vs. apparent size, rescan a folder, move to Trash (with safety checks), show in Finder

Requires macOS 14+ on Apple silicon or Intel (universal build).

## Download

Get the latest DMG from [GitHub Releases](https://github.com/steveo-ocheng/DiskScope/releases/latest), open it
and drag DiskScope to Applications.

Release builds aren't notarized yet (that needs an Apple Developer ID), so the first time you open DiskScope
macOS says it can't verify the developer. Open **System Settings › Privacy & Security**, scroll down and click
**Open Anyway**. On macOS 15 and later the right-click › Open shortcut no longer works for this. Each release
lists the DMG's SHA-256 (`shasum -a 256 DiskScope-*.dmg` to check it).

## Build from source

```sh
./build-app.sh            # build/DiskScope.app (universal, Hardened Runtime, ad-hoc signed)
./build-app.sh --install  # also copy to /Applications
./build-app.sh --dmg      # also make build/DiskScope-<version>.dmg
```

Run the tests (swift-testing, prints coverage): `Tests/run-tests.sh`. Set `SCRATCH=.build/other` to build in a
separate folder (e.g. to run two builds side by side).

For distribution to other Macs, sign with a Developer ID and notarize:

```sh
SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=<profile> ./build-app.sh --dmg
```

For complete results in protected folders (Mail, Messages…), grant DiskScope Full Disk Access in
System Settings › Privacy & Security.

## Releasing

Every push to `main` and every pull request runs the [CI workflow](.github/workflows/ci.yml): tests, then a
universal build (the zipped app is kept as a workflow artifact for 14 days).

To publish a release, push a version tag:

```sh
git tag v1.1.0 && git push origin v1.1.0
```

The [Release workflow](.github/workflows/release.yml) runs the tests, builds the universal app and DMG, and
publishes a GitHub release with the DMG and its SHA-256. "What's new" comes from
`.github/release-notes/<version>.md` if that file exists. If these repository secrets are set, the build is also
signed with a Developer ID and notarized: `MACOS_CERTIFICATE_P12` (base64 of the .p12),
`MACOS_CERTIFICATE_PASSWORD`, `MACOS_SIGN_IDENTITY`, `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`, `NOTARY_PASSWORD`
(an app-specific password). Without them it's ad-hoc signed and the notes include the Open Anyway steps.

## Getting an API key for Ask Claude

Ask Claude uses your own key from the Claude Console. It's billed separately from a Claude.ai Pro or Max
subscription (pay as you go; a typical question costs a few cents).

1. Sign in to the [Claude Console](https://platform.claude.com/), or create an account.
2. Add credit under [Settings › Billing](https://platform.claude.com/settings/billing).
3. Under [Settings › API Keys](https://platform.claude.com/settings/keys), click **Create Key** and name it "DiskScope".
4. Copy the key (it starts with `sk-ant-` and is shown only once), then paste it into **DiskScope › Settings ›
   Ask Claude** and click **Save**. Turn on **Enable Ask Claude**.
5. Optional: set a monthly spend limit under [Settings › Limits](https://platform.claude.com/settings/limits).
   Prices: [API pricing](https://platform.claude.com/docs/en/about-claude/pricing).

You can remove the key from DiskScope at any time (Settings › Remove Key) and revoke it in the Console.

## Security & privacy

- **Scanning reads metadata only.** A scan reads names, sizes and dates (`readdir` + `fstatat`); it never opens
  files. DiskScope collects no analytics or telemetry.
- **Offline by default.** The only network feature is the optional **Ask Claude** panel. It's off until you
  enable it and enter your own Anthropic API key (from the [Claude Console](https://platform.claude.com/settings/keys)) in DiskScope › Settings; the key is
  stored in the macOS Keychain and usage is billed to your key. Nothing is sent until you press Send. Then
  DiskScope sends a text summary of the scan to Anthropic's API over HTTPS, for Claude Opus 5.5 to answer: file and
  folder names relative to the scan root (your home folder shown as `~`), sizes, dates and the "Not in scan"
  breakdown. "What gets sent" shows exactly what will be sent before you send it. File contents are never sent,
  and Claude can only answer — it can't open, move or delete anything.
- **File contents are read only when you ask, and stay on your Mac.** Find Duplicates reads files to compute
  their checksums, and its side-by-side preview reads the copies you're comparing. Contents are never uploaded,
  not even by Ask Claude. Only
  regular files are opened (never symlinks, FIFOs or devices), and cloud placeholders (iCloud Drive, Dropbox and
  other File Provider files that aren't stored locally) are skipped, so nothing gets downloaded. Previews use
  Apple's system frameworks (ImageIO, AVFoundation, PDFKit, Quick Look), the same ones Finder uses.
- **"Not in scan" uses system figures.** It reads per-volume usage from the file system and runs
  `tmutil listlocalsnapshots` (read-only) to count local snapshots.
- **Never follows symlinks.** Entries are `lstat`-ed relative to their directory's descriptor, and each
  subdirectory is checked (device + inode) after opening, so a folder swapped for a symlink mid-scan
  can't redirect the scan elsewhere. Names that aren't valid UTF-8 are flagged, not traversed.
- **Move to Trash is guarded.** System paths, top-level and home folders and whole volumes are refused.
  Right before moving, each item is re-verified: the enclosing folders must still be the same real path
  (scan roots are canonicalized with `realpath`), and the item must be the same kind — and for files the
  same size and modification time — as when scanned. The confirmation lists full paths with
  control/bidi characters made visible. Items go to the Trash (recoverable), never deleted.
- **Find Duplicates changes nothing.** It only reads and compares. Removing duplicates happens in a script you
  review and run yourself; it's a dry run unless you pass `--apply`, never removes the last copy of a set, and
  re-hashes each file and its kept copy right before moving it to the Trash, skipping anything that changed.
  The file is saved without execute permission.
- **CSV exports are spreadsheet-safe.** Values a spreadsheet could treat as formulas are neutralised, so opening
  an export can't run anything.
- **No implicit launching.** Double-clicking an app, script, installer or executable reveals it in Finder
  instead of running it; opening it requires an explicit menu choice.
- **Hardened Runtime, no special entitlements.** Not sandboxed by design: measuring a whole disk needs access the
  App Sandbox doesn't allow. Distribute with a Developer ID signature and notarization (see above).

## License

MIT — see [LICENSE](LICENSE).
