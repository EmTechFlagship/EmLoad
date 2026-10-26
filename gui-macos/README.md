# EmLoad for macOS (SwiftUI)

A native SwiftUI shell for the existing EmLoad Python engine. It speaks the
same newline-delimited JSON-RPC protocol as the WinUI app (`emload rpc`), so
there is exactly one implementation of Apple ID auth, provisioning, signing,
installation, refresh and the Nugget tweak schema.

```
EmLoad.app (SwiftUI)
      │  JSON lines over stdin/stdout
      ▼
python -m emload rpc
      │
      ├── gsa / anisette      Apple ID + 2FA
      ├── provision           certificates, App IDs, profiles
      ├── signing / zsign     IPA re-signing
      ├── device / usbmuxd    USB + Wi-Fi device I/O
      ├── sideload / registry install + 7-day refresh
      └── nugget              SpringBoard / daemons / Liquid Glass
```

## Requirements

- Apple silicon or Intel Mac
- macOS 13 Ventura or newer
- Xcode 15+ command line tools (Xcode 26 is needed to *compile* the Liquid
  Glass APIs; older toolchains can build the macOS 13 fallback if you remove the
  macOS 26 branches)
- Python 3.10+ with the engine installed:
  ```bash
  python3 -m venv .venv
  .venv/bin/python -m pip install -e .
  .venv/bin/python -m emload setup
  .venv/bin/python -m emload doctor
  ```
- An iPhone/iPad with Developer Mode enabled and a trusted pairing
- `zsign` (the build script compiles it for this Mac and bundles it; Settings
  can also download the official Apple silicon release or compile from source)

The macOS app is not sandboxed: it needs to spawn Python, talk to `usbmuxd`,
and read/write the user's Application Support folder.

## Build

```bash
./scripts/build-app.sh          # -> dist/EmLoad.app
RUN=1 ./scripts/build-app.sh    # build, sign and launch
```

### Beta release builds

Pushing a versioned beta tag (for example, `v0.1.0-beta1`) runs the
`Release` GitHub Actions workflow. You can also run that workflow manually
with a beta channel such as `Beta 1`. It builds
`EmLoad-0.1.0-beta1-macos.dmg` and
`EmLoad-0.1.0-beta1-macos.zip` for Apple silicon and Intel, attaching both to
the same prerelease as the Windows installers. A single-architecture build is
named `macos-arm64` or `macos-x86_64` instead. Open the DMG and drag
`EmLoad.app` onto the Applications shortcut to install. The ZIP contains the
app bundle directly. The app is ad-hoc signed, not notarized. Use only on
macOS 13 or newer, and follow the setup instructions above for the Python
engine requirements.

The build script produces a universal app when both slices compile, and
otherwise keeps the host architecture. It also compiles `zsign` (from
`ZSIGN_SRC`, `~/zsign`, or a clone of zhlynn/zsign) and copies it into the
bundle. The script:

1. runs `swift build -c release` for x86_64 and arm64;
2. assembles `EmLoad.app/Contents/{MacOS,Resources}`;
3. copies the repo's `emload/` package and `pyproject.toml` into
   `Contents/Resources/engine/`;
4. writes the checkout path to `Contents/Resources/engine-root.txt`;
5. compiles `zsign` and installs it in the bundle and in Application Support;
6. ad-hoc signs the bundle (`codesign --force --deep --sign -`).

You can also open `Package.swift` in Xcode and run the `EmLoadMac` scheme. The
app bundle is only produced by the script; Xcode's debug build will look for
the checkout using the same `PythonLocator` rules.

### If `swift build` fails with the Xcode license

```
You have not agreed to the Xcode license agreements.
```

Run `sudo xcodebuild -license` once in Terminal, then retry. This is an Xcode
installation issue, not an EmLoad one.

## Liquid Glass

The window is built for macOS 26 (Tahoe) and degrades cleanly:

| Surface | macOS 26+ | macOS 13–15 |
| --- | --- | --- |
| Window backdrop | `NSGlassEffectView` over `NSVisualEffectView` | `NSVisualEffectView` (`.underWindowBackground`) |
| Sidebar selection | `.glassEffect(.regular.interactive())` | `.quaternary` capsule |
| Cards | `.glassEffect(.regular)` | `.ultraThinMaterial` + hairline stroke |
| Primary buttons | `.buttonStyle(.glassProminent)` | `.borderedProminent` |
| Secondary buttons | `.buttonStyle(.glass)` | `.bordered` |

The window is transparent (`isOpaque = false`, clear background) with a
hidden title bar and full-size content view, so the glass reaches behind the
traffic lights and the desktop shows through. If **Reduce Transparency** is
enabled, the app uses a solid window background instead.

All macOS 26 API use is behind `if #available(macOS 26.0, *)`; the deployment
target is macOS 13.

## Python discovery

`PythonLocator` checks, in order:

1. `EMLOAD_PYTHON` (full path to an interpreter)
2. `EMLOAD_ROOT` + `.venv/bin/python3` / `python`
3. The checkout recorded in `Contents/Resources/engine-root.txt`
4. `Contents/Resources/engine` (bundled source)
5. Common checkout folders (`~/EmLoadServer`, `~/Developer/EmLoadServer`, …)
6. `/opt/homebrew/bin/python3`, `/usr/local/bin/python3`, `/usr/bin/python3`,
   then `python3` on `PATH`

To point a build at a different engine:

```bash
EMLOAD_PYTHON=/path/to/python3 open gui-macos/dist/EmLoad.app
# or
EMLOAD_ROOT=/path/to/EmLoadServer open gui-macos/dist/EmLoad.app
```

Note that Finder-launched apps get a minimal `PATH`. If the engine starts but
reports missing packages, run `emload doctor` with the same interpreter the app
would pick, or set `EMLOAD_PYTHON` to the venv's `bin/python3`.

## Layout

```
gui-macos/
├── Package.swift
├── Resources/
│   ├── Info.plist
│   └── E.png                   sidebar brand mark
├── scripts/build-app.sh
└── Sources/EmLoadMac/
    ├── AppState.swift            engine lifecycle, events, settings
    ├── Services/
    │   ├── RPCClient.swift       NDJSON client + reader threads
    │   ├── PythonLocator.swift   interpreter / checkout discovery
    │   └── Models.swift          JSON → Swift models
    ├── UI/
    │   ├── RootView.swift        @main app entry, shell, header/status bar
    │   ├── Glass.swift           Liquid Glass backdrop, cards, buttons
    │   ├── BrandMark.swift       E.png logo with an SF Symbol fallback
    │   ├── Components.swift      shared layout pieces
    │   ├── SidebarView.swift
    │   ├── LoginSheet.swift      2FA sign-in
    │   └── LogSheet.swift
    └── Pages/
        ├── DevicesView.swift
        ├── SideloadView.swift
        ├── LibraryView.swift
        ├── MiscView.swift        dynamic Nugget schema renderer (hidden)
        ├── AccountView.swift
        ├── SettingsView.swift
        └── DiagnosticsView.swift
```

## Hidden pages and developer switches

`Misc Tweaks` stays fully implemented but is not listed in the sidebar. The
executable honours `EMLOAD_SECTION` for the initial page, so it remains
reachable for development:

```bash
EMLOAD_SECTION=misc ./dist/EmLoad.app/Contents/MacOS/EmLoadMac
```

EmSideStore is disabled in the macOS UI until further notice: it is no longer
shown on the Devices page or in Settings. The views, models, status calls and
RPC methods remain in the source, so re-enabling it is a one-line change.

## Troubleshooting

**"The EmLoad engine could not start"**
Run the command shown in the error with the same interpreter:

```bash
/Users/you/EmLoadServer/.venv/bin/python -m emload doctor
```

**`ModuleNotFoundError: requests` / `pymobiledevice3`**
The app found a system Python without the engine's dependencies. Create a venv
in the checkout, `pip install -e .`, and relaunch (or set `EMLOAD_PYTHON`).

**No devices**
Unlock the phone and tap Trust. Check `emload devices` in Terminal. On macOS,
`pymobiledevice3` uses `usbmuxd` from the system; no Apple Devices app is
needed.

**Using EmLoad on an Intel Mac**
Build with `./scripts/build-app.sh` on that Mac, or install a universal
`macos` release. `zsign` is compiled from source during the build because
upstream only publishes an Apple silicon macOS binary. The app passes that
binary to the engine as `EMLOAD_ZSIGN`.

**The app opens but the window is invisible**
Make sure you launched the assembled `.app` (not the raw SwiftPM executable)
and that **Reduce Transparency** is off. The window backdrop intentionally
shows the desktop on macOS 26.
