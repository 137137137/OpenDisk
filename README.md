<div align="center">

<h1>Disk Manager</h1>

Analyzes your disk usage on macOS and shows it as an interactive sunburst chart. Scans a full drive in seconds and streams results live while it runs.

[![downloads](https://img.shields.io/github/downloads/137137137/Disk-Manager/total.svg?style=flat)](https://github.com/137137137/Disk-Manager/releases)
[![release](https://img.shields.io/github/release/137137137/Disk-Manager.svg?style=flat)](https://github.com/137137137/Disk-Manager/releases/latest)
[![license](https://img.shields.io/github/license/137137137/Disk-Manager.svg?style=flat)](LICENSE)
[![platform](https://img.shields.io/badge/platform-macOS-blue.svg?style=flat)](https://www.apple.com/macos/)

<img src="docs/screenshot.png" alt="Disk Manager showing an interactive sunburst chart beside a sortable folder list" width="900"/>

</div>

## Features

- Interactive sunburst chart, where each ring is one level deeper into the tree.
- Hover any slice to see its exact size, click to zoom into that folder.
- Sortable, Finder-style folder list beside the chart, with breadcrumbs.
- Results stream in live during the scan, so the chart and list fill in as it runs.
- Incremental rescans reuse the previous scan and replay filesystem events, so a repeat scan is 20–28x faster than a cold one.
- Understands APFS volume groups, firmlinks, purgeable space, and system volumes, so the total matches what your Mac reports as used.
- External drives appear automatically when connected.

## Benchmarks

Full scan of a 1 TB Apple Silicon volume, cold cache.

<div align="center">
<img src="docs/benchmark.svg" alt="Bar chart comparing full-scan time on a 1 TB drive" width="520"/>
</div>

| Tool          | 1 TB scan | Relative    |
| :------------ | :-------: | :---------- |
| Disk Manager  | 17s       | 1x          |
| DaisyDisk     | 37s       | 2.2x slower |
| Baobab        | 2m 15s    | ~8x slower  |

## Requirements

- macOS on Apple Silicon or Intel.
- Full Disk Access, otherwise macOS hides parts of the filesystem and the totals come up short. Grant it in **System Settings → Privacy & Security → Full Disk Access**. The app prompts for it on first launch.

## Building

Open `Disk Manager.xcodeproj` in Xcode and run, or build from the command line:

```sh
xcodebuild -project "Disk Manager.xcodeproj" -scheme "Disk Manager" build
```

## How it works

- Reads directory metadata in bulk with `getattrlistbulk(2)` and `searchfs(2)` instead of one `stat` per file.
- Uses a small number of concurrent readers (4–5 for subtrees, ~8 for a whole volume), since APFS serializes directory reads and throughput drops off past that point.
- Runs the blocking reads on a fixed pool of dedicated worker threads pulling from a shared work stack.
- Stops at mount points and snapshot volumes using a per-child mount flag, so scanning `/` does not count the disk twice.

## Contributing

If you want, you can fork the code, make improvements and submit a pull request to improve the app. Accepting a PR is solely in the hands of the maintainer. Before making fundamental changes expecting them to be accepted, please consult the maintainer of the project first.

## Project layout

```
Disk Manager/
├── App/                    App entry point
├── Models/                 Folder items, chart data, scan progress
├── Services/
│   ├── DiskAnalyzer.swift  Top-level scan orchestration
│   └── Scanning/           Scanner core
│       ├── ScanEngine.swift        Strategy selection and streaming snapshots
│       ├── TraversalScanner.swift  getattrlistbulk worker pool
│       ├── CatalogScanner.swift    searchfs catalog scans
│       ├── ScanCache.swift         Incremental rescan cache
│       └── SystemInterop/          Wrappers over the kernel APIs
├── Views/
│   ├── Charts/             Sunburst rings chart
│   ├── Analysis/           Results screen
│   └── Components/         Rows, breadcrumbs, status bar
└── Resources/              Assets and icons
```

## License

Released under the [MIT License](LICENSE).
