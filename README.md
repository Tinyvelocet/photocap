<p align="center">
  <img src="Assets/miniphotocap.jpg" width="160" alt="photocap logo">
</p>

# photocap

**Reclaim disk space from Photos on macOS without ever touching iCloud.**

Photocap is a small, safe toolset for Macs with large iCloud Photo Libraries and
limited local storage. It frees space by deleting only the two **rebuildable**
caches Photos creates locally — the **Spotlight index** and **derivative
(thumbnail/preview) caches** — and optionally enforces a hard **APFS quota** so
the library can never balloon again. Originals always stay safe in iCloud.

> ✅ **Safety guarantee:** photocap only ever deletes the Spotlight index and
> derivative caches. It never deletes photos, the metadata database, or anything
> in iCloud. Everything it removes is regenerated automatically by Photos, or
> re-downloaded from iCloud on demand.

> ℹ️ photocap is an independent, open-source tool and is **not affiliated with or endorsed by Apple**.

---

## The problem

If you use **iCloud Photos with "Optimize Mac Storage"**, your Photos Library on
disk can still grow to hundreds of gigabytes. Why?

- Photos keeps a **Spotlight index** of every asset (can be larger than your
  originals).
- Photos keeps **derivative caches** (thumbnails, previews, edits) for fast
  browsing.

Both are *rebuildable*. Deleting them is harmless — Photos just rebuilds them as
needed and re-streams original files from iCloud. But macOS gives you no button
to do this cleanly, and the "Optimize" setting doesn't aggressively cap the
library size.

Photocap gives you that button, plus an optional hard quota.

---

## What's in the box

| Component | What it does |
|---|---|
| `photocap` (CLI) | `status`, `cloud`, `dryrun`, `prune`, `cap`, `setup-quota` commands |
| `photocap-gui` | A **menu-bar app** (no Dock icon) wrapping the engine with one-click pruning |
| `PhotocapEngine` | Shared Swift library: read-only parser + a pruner that only touches safe caches |
| `com.photocap.nightly.plist` | Optional launchd agent (template) that prunes caches nightly |

---

## Quick start (menu-bar app — easiest)

```bash
git clone https://github.com/Tinyvelocet/photocap.git
cd photocap
zsh install.sh
```

This builds the app and installs it to **/Applications/photocap.app**, then
launches it. Look for the 📷 icon in your **menu bar** (top-right).

In the menu:

1. It auto-detects your active Photos Library (or **Browse…** to pick one).
2. See the **usage bar** vs your cap, and the safe caches it found.
3. **Prune** individual caches, **Prune all**, or **Cap now** to aggressively
   shrink to your target size.
4. Toggle **Launch at login** so it's always available.
5. Every destructive action shows a **confirmation dialog** first.

> 💡 The first time you prune, Photos will rebuild thumbnails in the background.
> Your photos stay safe — they just re-download from iCloud as you view them.

> 🚦 **Status icons** in the menu bar: 📷 healthy · 🔄 working / scanning ·
> ⚠️ attention. A **red** ⚠️ means an error occurred (open the menu for a
> plain-language summary); an **orange** ⚠️ means Photos' background daemons are
> running and live pruning is paused until you quit Photos.

---

## The full workflow (recommended for aggressive space recovery)

1. **Quit Photos** (⌘Q) and wait for its background daemons to stop.
2. **Reclaim now** (one-time): prune the rebuildable caches with the CLI:
   ```bash
   swift build --configuration release
   .build/release/photocap cap --library ~/Pictures/Photos\ Library.photoslibrary
   ```
   This drops a 300+ GB library to ~40 GB with zero photo loss.
3. **Cap it permanently** (optional but powerful): create a 60 GB APFS quota
   volume and move your library there so it can never grow unbounded:
   ```bash
   .build/release/photocap setup-quota --cap 60000000000 --name PhotoCap
   # then copy your library to /Volumes/PhotoCap and set it as the
   # System Photo Library in Photos → Settings → General.
   ```
4. **Automate** (optional): install the nightly prune agent:
   ```bash
   INSTALL_NIGHTLY=1 zsh install.sh
   # or manually:
   sed "s|__PHOTOCAP_REPO_DIR__|$PWD|g" com.photocap.nightly.plist > \
     ~/Library/LaunchAgents/com.photocap.nightly.plist
   launchctl load ~/Library/LaunchAgents/com.photocap.nightly.plist
   ```

---

## CLI reference

```
photocap status   --library <path>     Show total size + per-category breakdown
photocap cloud    --library <path>     Show local vs cloud-resident asset counts
photocap dryrun   --library <path>     Show what prune would delete (no changes)
photocap prune    --library <path> [--target <name>] [--force]
photocap cap      --library <path> [--cap-bytes <n>] [--force]
photocap setup-quota --cap <bytes> [--name <VolumeName>] [--container <diskN>]
```

- `--force` skips the "Photos is running" safety check (use only when you've
  confirmed Photos is fully quit).
- `--target` is one of the safe caches (e.g. `database/search/Spotlight`,
  `resources/derivatives`). The engine refuses to prune anything not on its
  allow-list.

---

## How it stays safe

The pruner has a hard-coded allow-list (`Pruner.allowedTargets`). Any target
outside that list is rejected. The allow-list contains **only**:

- `database/search/Spotlight` — the Spotlight index
- `resources/derivatives` — derivative/thumbnail caches

Deleting these is the documented, reversible way to shrink a Photos Library
without losing content. iCloud remains the source of truth.

---

## Requirements

- macOS 14+
- Xcode command-line tools (`xcode-select --install`)
- Swift 6 toolchain (bundled with Xcode 16+)
- APFS volume (standard on modern macOS) for the quota feature

## License

MIT — see [LICENSE](LICENSE). Do whatever you like; iCloud stays yours.
