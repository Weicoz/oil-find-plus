<p align="center">
  <img src="./assets/readme/hero.en.svg" width="100%" alt="Oil Find Plus: Everything, for the Mac (Enhanced Edition). Press ⇧⌘F and results appear as you type.">
</p>

<p align="center">
  <a href="https://github.com/Weicoz/oil-find-plus/releases/latest"><b>Download DMG / ZIP</b></a>
  &nbsp;·&nbsp;
  <a href="./README.zh-CN.md">简体中文</a>
</p>

<p align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="./assets/readme/search-en-dark.png">
  <img src="./assets/readme/search-en-light.png" width="100%" alt="The Oil Find Plus search panel: readme is typed, eight results are ranked by relevance with the matching part in blue, and the footer shows the search took 0.2 milliseconds.">
</picture>
</p>

Oil Find Plus is a fast, lightweight file search tool for macOS (enhanced, fully open-source edition based on Oil Find) that works like Everything on Windows: it keeps its own in-memory index of every file name on your disk instead of relying on Spotlight. Press ⇧⌘F, a search field appears in the middle of the screen, and results update with every keystroke. When files are created, renamed or deleted, the index follows along in real time.

**Plus Features**:
- **Fully Integrated Open-Source Pro Capabilities**: Native document content full-text search (PDF, Word, RTF, TXT, etc.) and Apple Vision OCR image text retrieval (PNG, JPG, JPEG, HEIC, WEBP) included out of the box with no paid key required.
- **Local AI Conversation Search**: Search your on-device Claude Code, Claude desktop Code sessions, Codex, and WorkBuddy conversations; All searches files and topics together, and AI Topics narrows to conversations only. Regular Claude web chats, WorkBuddy cloud content not saved locally, archived or deleted WorkBuddy sessions, temporary Quick Asks, and subagent sessions are out of scope.
- **Full-Disk Content Coverage**: Search anywhere across user directories and external drives, with smart exclusion of system paths and dependency caches (`node_modules`, `Pods`, etc.).
- **Energy-Efficient Background Scheduling**: OCR and content indexing run under `qos: .background` on Apple Silicon efficiency cores with 80ms throttle sleeps—silent, cold, and fan-free.
- **Batch Transaction Commits**: Prevents SQLite FTS5 WAL disk bloating.
- **Anti-Flicker & Debounce**: Fixes FSEvents indexing feedback loops and UI list flickering.

## Improvements over upstream

This repository builds on the upstream release with the optimizations below. Every number is measured on an Apple M5 with 24 GB of memory (`oilfind-cli` plus `phys_footprint` from Activity Monitor).

| Area | Upstream | This repository |
| --- | --- | --- |
| Resident index memory | Index lives on the heap | Swapped back to a read-only file mapping after every save, heap pages returned: 135.8 MiB to **1.80 MiB**; idle app measured **364 MB to 76 MB** |
| Whole-disk rebuild peak | Scan buffers and index resident at the same time | Buffers are copied and handed back worker by worker, pages returned immediately: peak **163 MB to 75 MB (-56%)** |
| Background rebuild CPU | Multi-threaded full-speed rebuild | One thread capped at 4000 entries/s (`OILFIND_SCAN_EPS` to override), removing the 90% CPU spikes |
| Cold start | Rebuilds the ~13 MB hash table on launch | The hash table ships inside the index file (v4); load takes **0.15-0.26 s** with no rebuild |
| List refresh | The list refreshes on every index change | 0.6 s debounce, cutting the flicker loop caused by index writes |
| Launch behaviour | Starts quietly in the background | Activates and opens the search panel on launch |
| Update source | Official update service | This repository's GitHub Releases (`updates/latest.json`) |
| Pro features | Closed-source and paid, licence key required | Every feature in the same download, no licence key and no expiry |
| Content indexing energy | — | Extraction queue runs at `qos: .background`; image OCR yields 80 ms per image |
| SQLite footprint | — | Batched FTS5 transactions, memory released after commit, 256 MB read-only mapping |

Upstream 1.7.x features (local AI conversation search and the packaged-launch fix) are merged into this repository.

## Why it's fast

- **File names live in one contiguous block of memory.** Hundreds of thousands of names are stored column by column and scanned front to back, with no per-file objects.
- **Matching runs in C with NEON.** Character comparisons use Apple silicon's vector instructions in batches.
- **Each keystroke narrows the last result.** Typing one more character only searches what already matched.
- **Only changes get updated.** FSEvents reports what changed and the index is updated incrementally. After a restart, Oil Find catches up from where it left off.

Measured on an Apple M5 with 24 GB of memory, using the command-line tool in this repository. Each query ran 20 times; the table shows the median.

| Index scope | Files | Indexing | Resident memory | `readme` | `wd` (pinyin) | `kind:image` |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Default | 850K | 3.0 s | 45 MB | 0.6 ms | 0.3 ms | 3.9 ms |
| Whole disk | 7.5M | 27.2 s | 343 MB | 8.1 ms | 3.4 ms | 3.8 ms |

The default scope leaves out dependency folders, app and package internals, Library and system folders. You can turn each of them on in Settings. A single letter matches the most files and is the slowest case: about 11 ms in the default scope and about 58 ms for the whole disk.

## Search syntax

| Type | Meaning |
| --- | --- |
| `wd`, `wendang` | Pinyin initials or full pinyin, finds 文档 |
| `foo bar` | Contains both foo and bar |
| `foo \| bar` | Contains foo or bar |
| `readme !node_modules` | Contains readme, not inside node_modules |
| `*.png` | Wildcards match the whole name |
| `~/Desktop/ png` | Only under the Desktop |
| `ext:pdf;docx` | By extension |
| `kind:image` | By kind: folder, app, doc, image, video, audio, code, archive |
| `file:`, `folder:` | Files only, or folders only |
| `size:>10mb`, `size:1mb..5mb` | By size |
| `dm:today`, `dm:week`, `dm:2026-10-01` | By modification date |
| `regex:^IMG_\d+` | Regular expressions |

You can paste paths straight from a terminal or editor: `file://` URLs, quoted or escaped paths and paths ending in `:line:column` all work. Press ⌘/ in the search field for a syntax reference.

## Keyboard

| Key | Action |
| --- | --- |
| <kbd>⇧</kbd><kbd>⌘</kbd><kbd>F</kbd> | Open search (configurable in Settings) |
| <kbd>Return</kbd> | Open |
| <kbd>⌘</kbd><kbd>Return</kbd> | Show in Finder |
| <kbd>Space</kbd> / <kbd>⌘</kbd><kbd>Y</kbd> | Quick Look (Space after selecting a result) |
| <kbd>⌘</kbd><kbd>C</kbd> / <kbd>⌥</kbd><kbd>⌘</kbd><kbd>C</kbd> | Copy path, copy name |
| <kbd>⌘</kbd><kbd>⌫</kbd> | Move to Trash |
| <kbd>Tab</kbd> / <kbd>⌘</kbd><kbd>1</kbd>…<kbd>9</kbd> | Switch kind |
| <kbd>⌘</kbd><kbd>/</kbd> | Syntax reference |

You can also drag results into other apps.

## Oil Find Pro

The free version is open source and free forever. Pro is the add-on built on top of it, fully open source and built in by this repository.

| | Free | Pro |
| --- | :---: | :---: |
| Search by file name: pinyin, wildcards, regex, filters by kind, size and date | ✓ | ✓ |
| Local AI topics: Claude Code, desktop Code sessions, Codex, and WorkBuddy | ✓ | ✓ |
| Live updates, Quick Look, drag and drop, full keyboard control | ✓ | ✓ |
| Excluded folders and file types, in-app updates | ✓ | ✓ |
| External drives: indexed when plugged in, kept up to date | ✓ | ✓ |
| External drives stay searchable when unplugged | | ✓ |
| Image content: text and objects in screenshots and photos | | ✓ |
| Document content: PDF, Word, PowerPoint, Excel, Pages, Markdown and more | | ✓ |
| Source code | Open source, MIT | Open source, MIT |

Pro and the free version are the same download:

- Apps built from this repository include every feature, with no license key and no expiry.
- Images and documents are processed on your Mac and never uploaded.

## Install

1. Download `OilFind-Plus-v1.7.1-plus-macOS-arm64.dmg` (or the zip on the same page) from [Releases](https://github.com/Weicoz/oil-find-plus/releases/latest) and drag Oil Find Plus into Applications.
2. The first time you open it, macOS blocks it because it isn't notarized by Apple. Go to System Settings → Privacy & Security and click Open Anyway near the bottom.
3. Press ⇧⌘F and start typing.
4. Optional: grant Full Disk Access to also search mail attachments and other apps' data. Oil Find works fine without it.

When a new version is out, Oil Find tells you; click Update and Restart. You can turn off automatic checks in Settings.

The download includes Pro; no activation is needed. See [Oil Find Pro](#oil-find-pro) above for the difference.

To uninstall, quit Oil Find Plus and delete Oil Find Plus from Applications and `~/Library/Application Support/Oil Find`.

## Build from source

Requires macOS 14 and Swift 5.10 or later (Xcode 15.3 or newer).

```sh
git clone https://github.com/Weicoz/oil-find-plus.git
cd oil-find-plus
swift test
scripts/build-dmg.sh   # builds build/OilFind-Plus-v1.7.1-plus-macOS-arm64.dmg
scripts/install.sh     # builds and installs into Applications
```

This repository includes full Pro functionality built-in and open-source out of the box with no license key needed. Self-built apps use ad-hoc signatures; upon first run, permit the application in "System Settings" -> "Privacy & Security".

## Privacy

- File-name search reads names, sizes, and modification dates only; local AI conversation search additionally reads locally saved titles and conversation text from Claude Code, Codex, and WorkBuddy, and never uploads them. With image or document content search on, it parses files on your Mac using background efficiency cores. All data and FTS indexes stay 100% local on your Mac.
- The index stays on your Mac in `~/Library/Application Support/Oil Find/`.
- A daily update check fetches one version file and sends no device or usage data. You can turn it off in Settings.
- Nothing else is reported about your device or usage.

## Project layout

| Folder | Contents |
| --- | --- |
| `Sources/COilFind` | C: batched directory reads, name comparison, search scoring |
| `Sources/OilFindCore` | Scanning, indexing, queries, live updates, persistence, app updates |
| `Sources/OilFindApp` | The AppKit app and Settings |
| `Sources/OilFind` | The app's entry point |
| `Sources/oilfind-cli` | Command-line tool for benchmarks and troubleshooting |
| `Pro/Sources/OilFindPro` | Pro extension: SQLite FTS5 content search, document extractors, Vision OCR |
| `scripts` | Packaging (`build-app.sh`, `build-dmg.sh`) and installation scripts |

## License

This repository is licensed under the [MIT](./LICENSE) license.

The code in this repository is licensed under [MIT](./LICENSE). The Pro module isn't in this repository and isn't open source; the builds on Releases and the website include it.
