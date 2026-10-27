# EmLoad

Sideload iOS apps with a free Apple ID — an AltServer-style toolkit with a
**Python CLI** and a **PySide6 desktop app**.

No jailbreak. No paid developer account. EmLoad talks to Apple directly, the
same way Xcode does, and to your iPhone over USB/Wi-Fi through
`pymobiledevice3`.

```
┌─────────────────────┐   engine (Python)   ┌──────────────────────────┐
│ emload (CLI)        │                     │ Apple ID auth (GrandSlam)│
│ emload-gui (PySide6)│ ──────────────────▶ │ + anisette (in-process)  │
└─────────────────────┘                     │ + provisioning API       │
                                            │ + zsign code signing     │
                                            │ + pymobiledevice3 device │
                                            └──────────────────────────┘
```

## Features

- **Install any `.ipa`** with a free Apple ID, over USB or Wi-Fi
- **Apple ID sign-in in-process**: GrandSlam (SRP-6a) over TLS pinned to
  Apple's CA. Your password, verification code, and Apple session tokens never
  leave your machine and are not stored anywhere.
- **Automatic provisioning**: registers your device, issues a 7-day development
  certificate, creates the App ID, and downloads the profile — all via Apple's
  `developerservices2` API
- **Code signing with `zsign`** (SHA-256 CodeDirectory) — `emload setup`
  downloads a prebuilt Windows binary for you
- **App-Store-encrypted detection**: EmLoad refuses FairPlay-encrypted IPAs
  before wasting a round trip
- **Team-scoped bundle IDs** for free accounts, plus optional overrides
  (display name, bundle id, version) and extension stripping
- **7-day refresh**: every install is recorded with its expiry; `emload refresh`
  (or the GUI's Library tab) re-signs and reinstalls before the profile expires
- **Automatic profile repair**: if the device rejects an app during
  verification, EmLoad retires the old provisioning profile (from the cache and
  the device) and automatically issues, re-signs, and reinstalls with a fresh
  one — up to 2 re-issues per install
- **EmSideStore (AltServer alternative)**: watch usbmuxd and, the moment an
  iPhone/iPad is plugged in, automatically sideload **SideStore** (the
  AltStore/SideStore alternative, bundle id `com.SideStore.SideStore`) onto it
  with your signed-in Apple ID — the same trick AltServer uses to bootstrap
  AltStore. The IPA is taken from `~/SideStore`, a matching versioned folder in
  `~/Downloads`, a previously downloaded copy, or the latest published GitHub
  release (stable / alpha / nightly). Runs as `emload emside-store watch`,
  one-shot with `emload emside-store install`, or from the GUI's Devices page.
  `emload emside-store serve` also exposes a small JSON API so the phone can
  request installs and import EmLoad's signing certificate into LiveContainer.
- **Live install progress** in both CLI and GUI (upload MBs + installd phases)
- **JIT**: attach the device debugger to a sideloaded app and detach, which
  turns on just-in-time compilation until that process quits. Available from
  `emload jit` and the macOS app's JIT page. Needs Developer Mode and a
  development signature (`get-task-allow`, which EmLoad's profiles include)
- **Miscellaneous tweaks (Nugget-based)**: SpringBoard options, daemon toggles
  and Liquid Glass settings applied with the sparserestore backup-restore
  exploit on iOS 17.0 - 18.1, or **BookRestore** (AFC / Restore methods) on
  iOS 18.2+. **iOS 27 applies are hard-blocked**: Apple's changed setup flow
  does not honor skip-setup, so an apply can leave the device on the white
  "Swipe up to upgrade" screen (and swiping it can reset the device). No
  jailbreak, plus a WebKit-overload respring. Applies skip-setup
  configuration by default so the post-reboot "Swipe up to upgrade" flow
  is skipped on OS versions that honor it and on-device settings aren't reset.
- **Diagnostics** (`emload doctor`) that tell you exactly what's missing

## Requirements

- Windows 10/11, Linux, or a Mac (native macOS app on Apple silicon and Intel)
- Python 3.10+ (3.12 recommended — `pymobiledevice3` needs prebuilt wheels)
- Apple **Devices** (or iTunes) from the Microsoft Store on Windows — that's what
  provides the USB/`usbmuxd` service
- An Apple ID (a spare one is a good idea)
- An iPhone with **Developer Mode** enabled (iOS 16+, `Settings → Privacy &
  Security → Developer Mode`) if you're on a recent iOS

## Install

### Windows installer (recommended)

Download these from the **0.1.0 Beta 1** release:

| File | What you get |
| --- | --- |
| `EmLoad-Setup-0.1.0-beta1.exe` | WinUI 3 desktop app + Python engine |
| `EmLoad-Cli-Setup-0.1.0-beta1.exe` | `emload` on your PATH (plus `emload gui` if you keep PySide6) |
| `EmLoad-0.1.0-beta1-win-x64.zip` | Portable folder, no installer — run `First-Run.cmd` |

The prerelease also includes `EmLoad-0.1.0-beta1-macos.dmg` for a
drag-and-drop install on Apple silicon and Intel Macs, plus a ZIP archive. See
[gui-macos/README.md](gui-macos/README.md) for macOS requirements and setup.

Both installers are **per-user and need no admin rights**. They install to
`%LOCALAPPDATA%\Programs\EmLoad` (desktop) or `...\EmLoad CLI`, create a private
virtual environment there, and install `requirements.txt` into it. That means:

- **Python 3.10+ must already be installed** — use the
  [python.org](https://www.python.org/downloads/windows/) build, not the
  Microsoft Store stub. The installer finds `py -3.12`/`python`/registry
  installs automatically and prefers 3.12/3.13.
- The desktop installer skips the optional PySide6 GUI (~150 MB) unless you
  tick it; the CLI installer includes it by default.
- An internet connection is needed while the installer fetches the packages
  (build with `-Offline` to carry a wheelhouse instead).

After installing, run once from a terminal:

```powershell
emload setup        # downloads zsign (required for signing)
emload doctor       # check your environment
```

Uninstall from **Settings → Apps**. Your Apple ID sign-in, certificates and
install history in `%LOCALAPPDATA%\EmLoad` are kept.

### From source

```powershell
git clone https://github.com/EmTechFlagship/EmLoadServer
cd EmLoadServer
py -3.12 -m venv .venv
.\.venv\Scripts\python -m pip install -e .          # CLI + engine
.\.venv\Scripts\python -m pip install -e ".[gui]"   # + PySide6 GUI
emload setup        # downloads zsign (required for signing)
emload doctor       # check your environment
```

> Installing PySide6 only adds the PySide6 GUI; the CLI works without it via
> `pip install -e .` alone.

### Building the installers

```powershell
powershell -File installer\build-installer.ps1
```

Releases are built by CI: push a tag such as `v0.1.0-beta1` and
`.github/workflows/release.yml` builds the three artifacts and publishes them
as a GitHub release. See [installer/README.md](installer/README.md) for the
version knobs, offline builds and how the engine bootstrap works.

## CLI

```
emload doctor                check the environment for sideloading readiness
emload devices               list connected iOS devices
emload device-info [--udid]  show details for one device
emload login --email you@icloud.com        sign in (prompts for password;
                                           enter the 2FA code when prompted)
emload login --email x --password y --code 123456   finish 2FA
emload account               show the signed-in account
emload logout [--email]      sign out
emload provision <bundle_id> provision the signed-in team (cert + device + App ID)
                             and install the profile on the connected device
emload inspect app.ipa       read an IPA's identity without extracting it
emload sideload app.ipa [options]   provision + sign + install in one step
emload refresh [--all]       re-sign + reinstall recorded apps before expiry
emload installs              list recorded sideloads with days left
emload forget <bundle_id>    stop tracking a sideload
emload apps                  list apps installed on the device
emload jit <bundle_id>       enable JIT for an installed app
emload uninstall <bundle_id> remove an app from the device
emload profiles              list provisioning profiles installed on the device
emload unprovision <uuid>    remove one provisioning profile (--all removes every one)
emload signed [--clean]      report / delete kept signed IPAs
emload setup                 download zsign (needed for signing)
emload emside-store status   EmSideStore state: sign-in, devices, IPA options
emload emside-store install  sideload SideStore onto connected device(s) now
emload emside-store watch    install or refresh SideStore on device attach
emload emside-store serve    run the HTTP API and EmLoad certificate transfer endpoint
emload gui                   launch the desktop app
```

Every command accepts `--json` for scripting. Device commands accept `--udid`
and `--connection usb|wifi|auto`.

> **JIT** (`emload jit <bundle_id>`): mounts the developer disk image, attaches
> debugserver, then detaches so the app can run JIT until it quits. If the app
> is not open, EmLoad launches it paused and attaches before its own code runs.
> `--running-only` refuses to launch it. `--relaunch` quits an already-open
> copy first, which is what apps that check for JIT at startup need. Requires
> Developer Mode and a development signature.

> **EmSideStore** options (status / install / watch / serve):
> - `--ipa PATH` — use a specific SideStore `.ipa` (default: auto-detect, then download)
> - `--download` / `--channel stable|alpha|nightly` — fetch the newest published
>   SideStore build from `embabyty/EmStore` GitHub releases
> - `--force` — reinstall even if SideStore is already on the device
> - `--udid UDID` — act on one device instead of every connected device
> - `serve` options: `--host ADDR` (default `127.0.0.1`), `--port PORT`
>   (default `1740`; deliberately not AltServer's 12345, so both can coexist)
> - re-sign options like `sideload`: `--display-name` (e.g. `SideStore`),
>   `--bundle-id`, `--keep-extensions`, `--keep-uisd`, `--file-sharing`,
>   `--keep-signed`, `--signed-dir`

> **EmSideStore API** (`emload emside-store serve`): the SideStore app on the
> phone talks to this HTTP server instead of AltServer — `GET /api/status`
> (sign-in state + local IPA, never session tokens), `GET /api/devices`,
> `GET /api/apps?udid=`, `POST /api/refresh` and `POST /api/install` (both
> return `202` + `job_id`; poll `GET /api/jobs/<id>`), `GET /api/jobs`. There
> is **no authentication** — keep it bound to localhost or a trusted LAN.
>
> To import EmLoad's signing certificate into LiveContainer, first provision
> EmLoad at least once, then start the API on your LAN:
> `emload emside-store serve --host 0.0.0.0`. On startup, EmLoad prints an
> HTTPS certificate-transfer URL, a per-run token, and the SHA-256 fingerprint
> of its pinned TLS certificate. Enter all three in LiveContainer's Settings
> \> Import/refresh certificate from EmLoad. The transfer endpoint requires
> the token and uses TLS; stop the server after importing. The transfer URL is
> available only while this command is running.

> **On Windows, if `emload` isn't on your PATH**, use the repo's `emload.bat`
> launcher instead (it always runs the project's `.venv`), e.g.
> `emload.bat doctor`. A bare `python -m emload` may hit a *different* Python
> on your PATH that lacks the dependencies.

Typical first sideload:

```powershell
emload doctor
emload login --email you@icloud.com
emload sideload MyApp.ipa
emload installs                 # see "6.9d left"
```

### Sideload options

```
emload sideload App.ipa \
  --display-name "My App" \
  --bundle-id com.example.myapp   # default: com.example.myapp.<TEAMID>
  --keep-extensions               # default strips .appex extensions
  --keep-uisd                     # default strips UISupportedDevices
  --file-sharing                  # enable Files-app sharing
  --keep-signed                   # keep <App>_Signed.ipa on disk
  --signed-dir D:\signed          # where signed files + scratch go
```

## GUI

```powershell
emload gui
# or on Windows: run.bat  (always uses the project's .venv)
```

The desktop app has a sidebar with seven pages:

- **Devices** — live inventory (USB + Wi-Fi), refreshed automatically as
  devices attach/detach. When a phone plugs in and the cached provisioning
  profile belongs to a *different* device, EmLoad registers the new device and
  installs a fresh profile on it automatically — reusing the same development
  certificate (certificates aren't device-specific, so re-issuing one per
  device would trip Apple's certificate limit; you can watch the profile
  install in the status bar). A toggle here also enables **EmSideStore**:
  every newly connected device gets SideStore installed or refreshed automatically
  (if signed in), just like AltServer bootstraps AltStore.
- **Sideload** — drag & drop an `.ipa`, see its icon/name/version, tweak
  options, pick the target device, and watch the install with a live progress
  bar and log
- **Library** — every sideload this machine has done, with days-left and
  one-click **Refresh** / **Uninstall** / **Forget**
- **Miscellaneous** — SpringBoard / Daemons / Liquid Glass tweak dialogs and
  a **Respring Device** button (Nugget-style apply: sparserestore on iOS
  17.0 - 18.1, BookRestore AFC or Restore on 18.2+; the dialogs expose
  apply-method and transfer-mode options)
- **Account** — Apple ID sign-in with a 2FA-aware dialog
- **Settings** — connection preference, signed-IPA folder, zsign download
- **Diagnostics** — `doctor` results rendered

### macOS app (SwiftUI)

`gui-macos/` is a native SwiftUI shell that drives the same Python engine over
the newline-delimited JSON-RPC bridge (`emload rpc`). It is not a second
implementation: sideloading, provisioning, signing, refresh and the Misc tweak
schema all stay in Python.

On **macOS 26 (Tahoe) or newer** the window, sidebar selection, cards and
primary buttons use **Liquid Glass** (`NSGlassEffectView` / `.glassEffect`),
with the desktop visible through the window backdrop. macOS 13–15 get the same
layout with `NSVisualEffectView` and `.ultraThinMaterial` instead, and
**Reduce Transparency** falls back to a solid window. The app runs on Apple
silicon and Intel Macs with macOS 13+. The build compiles `zsign` from source
(upstream does not publish an Intel macOS binary) and bundles it in the app.

```bash
# 1. Install the Python engine and its dependencies (once)
python3 -m venv .venv
.venv/bin/python -m pip install -e .
.venv/bin/python -m emload setup      # downloads zsign for macOS
.venv/bin/python -m emload doctor

# 2. Build EmLoad.app
./gui-macos/scripts/build-app.sh      # -> gui-macos/dist/EmLoad.app
open gui-macos/dist/EmLoad.app
```

The app looks for Python in this order: `EMLOAD_PYTHON`, a venv under
`EMLOAD_ROOT`, the checkout it was built from (recorded in
`Contents/Resources/engine-root.txt`), the engine copied into
`Contents/Resources/engine`, common checkout locations, then `python3` on
`PATH`. The bundled engine source still needs a Python with
`requirements.txt` installed; see [gui-macos/README.md](gui-macos/README.md)
for details and troubleshooting.

### EmLoadServer

`EmLoadServer/` is the Swift command-line host used with EmLoadStore. It pairs
a USB-connected iPhone, signs in to Apple through SideSign, and installs
EmLoadStoreCompanion. The EmLoad window calls the same library: while an
iPhone or iPad is connected, the sidebar shows **EmLoadStore Setup**.

The store app itself (the macOS library and the iOS companion) lives in
`EmLoadStoreLoader/`. Open `EmLoadStoreLoader/EmLoadStore.xcodeproj` and select
**EmLoadStore** for macOS or **EmLoadStoreCompanion** for iOS.

```bash
./EmLoadServer/scripts/build.sh
# -> EmLoadServer/.build/emloadserver
EmLoadServer/.build/emloadserver anisette-servers
```

The script compiles `x86_64` and `arm64` and joins them with `lipo` when both
slices succeed. A cross-compile that the toolchain cannot produce is skipped;
the host architecture is required. `ARCHS="x86_64"` or `ARCHS="arm64"` builds
one slice. Pairing still needs `idevicepair` on `PATH`. Build it for the Mac you
are on with:

```bash
./EmLoadServer/scripts/install-libimobiledevice.sh
export PATH="$HOME/.local/bin:$PATH"
```

Other people can use an anisette proxy on your Mac without your Apple ID,
development certificate, or saved anisette identity. The proxy only forwards
SideStore v3 requests, and each caller sends their own identifier:

```bash
EmLoadServer/.build/emloadserver proxy
# prints http://<this-mac>:1741/<token>
```

They point their own client at that URL (`emloadserver login --server <url>`,
or `EMLOAD_ANISETTE_SERVER` for the Python engine). `--open` removes the token
on a trusted network. `--upstream` selects a different anisette server; the
default is SideStore (New).

## How it works

1. **Device I/O** — `pymobiledevice3`: usbmux discovery, lockdown pairing,
   AFC staging, `installation_proxy` install, SpringBoard icons.
2. **Apple ID auth** — GrandSlam (Apple's modified SRP-6a) against
   `gsa.apple.com`, with a unique Mac anisette identity provisioned through a
   public v3 service. The service receives only the random device identity and
   opaque provisioning blobs; the Apple ID, password, verification code, and
   session tokens go directly between EmLoad and Apple. Two-factor auth is a
   two-step flow: trigger, then submit the code.
3. **TLS** — requests verify against `certifi` + Apple's root/intermediate CA
   (`emload/certs/apple_gsa_ca.pem`). Verification is never disabled.
4. **Provisioning** — `developerservices2.apple.com`: list team, submit CSR,
   register device, create App ID, download `embedded.mobileprovision`. The
   private key never leaves the machine; cert + profile are cached per account
   under `%LOCALAPPDATA%\EmLoad\`.
5. **Signing** — `zsign` re-signs the IPA with the provisioning profile, new
   bundle id, and stripped extensions, then the signed IPA is uploaded to the
   device via AFC and installed via installd.

## What Apple's free account won't let you do

- Apps stop opening after **7 days** until re-signed — refresh before then.
- Only **3 sideloaded apps** per device at once.
- Roughly **10 App IDs per 7 days**, so extension-heavy apps usually have to
  have their extensions removed.
- App Store downloads are **FairPlay-encrypted** and can't be re-signed — use a
  decrypted IPA.

## Troubleshooting

- **"Could not reach the Apple Mobile Device Service"** — install Apple Devices
  (or iTunes) from the Microsoft Store, then restart EmLoad.
- **"zsign not found"** — run `emload setup`. To use your own build, set
  `EMLOAD_ZSIGN` to the binary, put `zsign.exe` in `emload/vendor/`, or add it
  to `PATH`.
- **2FA code never arrives** — EmLoad's locale/timezone headers are
  normalized for Apple's endpoints; if you still see nothing, check that your
  trusted devices are reachable and try `--connection wifi` for the phone.
- **Path too long to sign** — choose a shorter "Signed IPA folder" in Settings.
- **Logs/state** — everything lives in `%LOCALAPPDATA%\EmLoad\` (accounts,
  anisette, signing material, `sideloads.json` registry). Delete it to reset.

## Security notes

- Passwords are used only for the sign-in handshake and never written to disk.
- Only short-lived session tokens (`adsid`, IDMS token, Xcode auth token) are
  cached, under the per-user data dir, never in source control.
- Apple's CA chain is pinned; `verify=False` appears nowhere.

## License

MIT. EmLoad is not affiliated with Apple Inc. Only install software you are
entitled to run.

The Miscellaneous tweak feature (the `emload.nugget` package and the dialogs
in `emload/gui/nugget_dialogs.py`) is ported from
[Nugget27](https://github.com/leminlimez/Nugget/), which is licensed under
the **AGPL-3.0**; ported files carry attribution headers. Same for the
respring HTML asset. Please respect that license if you reuse that code.
