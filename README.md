<div align="center">
  <img src="app/Resources/AppIcon-1024.png" width="180" height="180" alt="MagicKey app icon">
  <h1>MagicKey</h1>
  <p>Make your MacBook keyboard backlight breathe, pulse with keystrokes, and move to music.</p>
  <p>
    <img src="https://img.shields.io/badge/version-v2.1-B8D2FF?style=flat-square" alt="Version v2.1">
    <img src="https://img.shields.io/badge/macOS-14%2B-171A20?style=flat-square&logo=apple&logoColor=white" alt="macOS 14+">
    <img src="https://img.shields.io/badge/Apple%20Silicon-required-303640?style=flat-square&logo=apple&logoColor=white" alt="Apple Silicon required">
    <img src="https://img.shields.io/badge/Swift-5-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 5">
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-F4F7FF?style=flat-square" alt="MIT License"></a>
  </p>
</div>

[简体中文](./README.zh-CN.md) · [Architecture and design notes](./DESIGN.md)

MagicKey is a lightweight macOS menu bar app that adds static, breathing, heartbeat, strobe, key-pulse, and music-reactive effects to a MacBook's built-in keyboard backlight. Brightness, speed, minimum brightness, pulse duration, and music sensitivity are adjustable. When MagicKey stops or exits normally, it immediately restores the keyboard state that existed before takeover; after an abnormal termination, it restores any saved state the next time it launches.

## Installation

> [!IMPORTANT]
> **The release build is not notarized by Apple, so Gatekeeper will block its first launch.**
> This does not mean the archive is damaged; you must allow it once using one of the methods in
> [Gatekeeper blocks the first launch](#gatekeeper-blocks-the-first-launch).
> The release is also arm64-only and **will not launch on Intel Macs**.

### Download the release

Download `MagicKey-<version>.zip` from [Releases](https://github.com/XiaoSong1223/MagicKey/releases/latest), extract it, drag `MagicKey.app` into `/Applications`, and allow its first launch as described below.

### Gatekeeper blocks the first launch

The release has a local ad-hoc signature, no Developer ID signature, and no Apple notarization. Gatekeeper therefore rejects it:

~~~console
$ codesign -dv MagicKey.app
Signature=adhoc          TeamIdentifier=not set

$ spctl -a -t exec -vvv MagicKey.app
MagicKey.app: rejected
~~~

A browser-downloaded archive also carries the `com.apple.quarantine` attribute, which causes macOS to warn that it cannot verify the app. Choose any one of these **one-time** options:

**1. Allow it in System Settings**

Double-click `MagicKey.app` once so macOS records the block. Then open **System Settings → Privacy & Security**, scroll to the Security section, click **Open Anyway**, and confirm.

> [!NOTE]
> Starting with macOS 15, Apple removed the old Control-click/right-click → Open shortcut.
> Use System Settings instead.

**2. Remove the quarantine attribute in Terminal**

~~~bash
xattr -dr com.apple.quarantine /Applications/MagicKey.app
~~~

**3. Build from source**

A locally built app does not carry the browser quarantine attribute, so this specific prompt does not appear. See the next section.

> [!NOTE]
> **Launch at Login depends on code signing.** `SMAppService` requires a signature accepted by the system.
> Registration may fail for the ad-hoc-signed release; MagicKey reports that error in the UI and all
> other features continue to work. Source builds use a configured local development identity when one
> is available and otherwise fall back to ad-hoc signing.

### Build from source

The intended build environment is Xcode 26 or newer with the macOS 26 SDK:

~~~bash
xcode-select -p                          # Should point into /Applications/Xcode.app/...
xcrun --sdk macosx --show-sdk-version    # Should report 26 or newer
git clone https://github.com/XiaoSong1223/MagicKey.git
cd MagicKey
make -C app install
~~~

> [!IMPORTANT]
> The Liquid Glass appearance is determined by the SDK linked **at build time**, not by the macOS
> version running the app. A binary built with Command Line Tools and SDK 15 or older keeps the
> pre-Liquid-Glass appearance even on macOS 26. `app/Makefile` detects the SDK version and selects
> the appropriate code path automatically.

`make install` builds and locally signs the app, copies it to `/Applications`, and launches MagicKey. Click the keycap icon in the menu bar to choose an effect.

To uninstall:

~~~bash
make -C app uninstall
~~~

Turn off **Launch at Login** in MagicKey before uninstalling. The command removes only `/Applications/MagicKey.app`; it does not delete existing preferences.

> [!NOTE]
> MagicKey does not currently offer a Homebrew cask. Developer ID signing and notarization are also
> still pending; they would remove the Gatekeeper step and make Launch at Login reliable in release builds.

## Features

### Six backlight effects

| Mode | Behavior |
| --- | --- |
| Static | Holds the entire keyboard at the selected brightness |
| Breathe | Moves smoothly between the minimum and maximum brightness |
| Heartbeat | Repeats a strong pulse followed by a weaker pulse |
| Strobe | Alternates rapidly between bright and dark at an adjustable period |
| Key Pulse | Flashes the whole keyboard whenever you press a key |
| Audio Beat | Detects beats in system audio and drives the backlight |

### Mechanical keyboard sounds

MagicKey can play recordings of real mechanical keyboards when you type on the built-in keyboard. Sound playback and backlight effects are independent: use either feature by itself or both together.

- Twelve sound packs, ordered from crisp to quiet:

  | | | |
  |---|---|---|
  | **Crisp** (Box Navy) | **Clangy** (SKCM Blue Alps) | **Classic** (IBM Buckling Spring) |
  | **Thocky** (Holy Panda) | **Dense** (Topre) | **Full** (NovelKeys Cream) |
  | **Deep** (Gateron Ink Black) | **Muted** (Cherry MX Black) | **Rounded** (Gateron Ink Red) |
  | **Smooth** (Turquoise Tealios) | **Gentle** (Cherry MX Brown) | **Quiet** (Alpaca) |

- Separate press and release recordings, dedicated samples for Space, Return, and Backspace, and sound for modifier keys
- A held key plays only its press and release sounds instead of repeating with the system key-repeat rate
- Sample rotation plus small volume and pitch variations keeps repeated typing from sounding mechanical
- Loudness matching across all twelve packs prevents a sound-pack change from also becoming a volume change
- The audio engine pauses after about 30 seconds without typing and starts again on the next key press

#### Custom sounds for individual keys

You can also assign your own sample to an **individual key**. Open **Settings → Keyboard Sounds → Custom Key Sounds…** to display a MacBook keyboard map, then click a key and choose its sound.

- Supports common audio formats (`mp3`, `m4a`, `wav`, and `aiff`), with a two-second limit per sample
- Matches imported samples to the built-in packs' loudness target
- Copies imports to `~/Library/Application Support/MagicKey/CustomSounds/`, so moving or deleting the original file has no effect
- Replaces only the **press** sound; release still comes from the selected built-in pack
- Treats left and right Shift, Option, and Command as separate keys
- Includes a master toggle for A/B comparisons while preserving assignments

> [!NOTE]
> Touch ID does not generate a key event, so it does not appear on the keyboard map.
> Unless F1–F12 are configured as standard function keys in System Settings, pressing them generates
> a system brightness or volume event rather than a key event, so an assigned sound will not play.

> [!IMPORTANT]
> Keyboard sound playback is the **only** MagicKey feature that needs Input Monitoring permission.
> It is off by default and must be enabled explicitly. Without permission, MagicKey installs no
> keyboard event monitor and does not start the sound engine. After granting access in System Settings,
> **quit and reopen MagicKey** for the permission to take effect. The app reports this state and provides
> a Reopen button instead of claiming that sound playback is already active.

The enable switch and volume control are in the menu bar panel; choose the sound pack in Settings. The permission is located at:

~~~text
System Settings → Privacy & Security → Input Monitoring
~~~

### Automation and state protection

- Adjust brightness, speed, minimum brightness, pulse duration, and music sensitivity
- Render at 60 fps by default or switch to the 30 fps power-saving mode
- Stop automatically during sleep, screen lock, display sleep, or fast user switching, then resume when the session becomes active
- Pause after 120 seconds without input by default when no audio is playing
- Pause and return control of the keyboard while macOS Low Power Mode is enabled, then resume when it is disabled
- Launch at login, with clear errors when the signature or installation location does not meet system requirements
- Run entirely in the menu bar without occupying the Dock
- Save brightness, ambient-light auto-adjustment, and idle-dimming state before takeover, then restore them in the required order
- Detect and restore a state snapshot left by an abnormal termination on the next launch

### CLI and script integration

Let your own scripts trigger MagicKey. Flash the keyboard when a build, test run, deployment, or other long-running task finishes.

~~~bash
# Install by linking the script into PATH
ln -s "$PWD/scripts/magickey" /usr/local/bin/magickey
~~~

~~~bash
magickey flash                  # Flash 3 times
magickey flash --times 5        # Flash 5 times (range: 1–10)
magickey on                     # Enable the selected effect
magickey off                    # Disable it
magickey effect breathe         # Select an effect
magickey --help
~~~

Example uses:

~~~bash
npm run build && magickey flash             # Signal a completed build
make test || magickey flash --times 5       # Flash more urgently after failure
./deploy.sh; magickey flash --times 3       # Signal the end of a long task

# Use the URL directly without installing the script
open -g "magickey://flash?times=3"
~~~

**`flash` temporarily borrows the backlight and restores it as soon as the sequence ends.** It works even when the main effect is disabled or paused because you are away.

MagicKey silently drops the request and writes a log entry in these cases:

- **Screen lock, display sleep, or system sleep**, when nobody can see the signal and waking the backlight controller would waste power
- **Low Power Mode**, when a flash would restart the rendering loop that the system asked MagicKey to pause

`on`, `off`, and `effect` update the same persistent settings as the menu bar panel. `flash` is a one-time action and does not change any setting.

> This path requires **no additional system permission**. LaunchServices forwards the URL; MagicKey
> does not listen on a port or keep a socket open.
>
> `open` is asynchronous and provides no completion status. In `magickey flash && echo done`, the
> second command runs immediately rather than waiting for the flash sequence to finish.

### Menu bar status

| Icon | State |
| --- | --- |
| Outline keycap | MagicKey is stopped or temporarily paused because of lock, display sleep, or idle time |
| Filled keycap | A backlight effect is running |

The status icon uses macOS template images and adapts to light, dark, selected, and high-contrast menu bars.

## System requirements

- macOS 14 or newer
- An Apple Silicon MacBook; the release is an arm64-only binary and **does not run on Intel Macs**
- A built-in backlit keyboard
- macOS 14.2 or newer for Audio Beat
- The UI is designed and tested for macOS 26. On macOS 14–15, all functionality is present while Liquid Glass falls back to the standard system appearance and a tinted outline marks the selected effect. This fallback has not yet been verified on physical hardware.

MagicKey targets a MacBook's built-in keyboard backlight. External keyboards are outside its supported scope.

## Hardware limitations

> [!IMPORTANT]
> MagicKey cannot change the backlight color or control individual keys. Every LED in the built-in
> MacBook keyboard shares one global brightness channel, so every effect applies to the whole keyboard.

This is a hardware limit rather than a permission or driver limit. `root` access, a kernel driver, or a private API cannot create RGB or per-key controls that the hardware does not provide. See [DESIGN.md](DESIGN.md) for measurements, constraints, and the resulting design choices.

## Permissions and privacy

| Feature | Permission or network behavior | Data handling |
| --- | --- | --- |
| Static, Breathe, Heartbeat, Strobe | No additional permission | Writes only the keyboard's global brightness value |
| Key Pulse | No Input Monitoring permission | Reads only the global key-event count and time since the latest event; it does not read keycodes or typed content |
| Audio Beat | System Audio Recording, **not** microphone access | Reduces audio in memory to low-frequency energy and beat events, then discards it |
| Keyboard sounds | Input Monitoring, **off by default** | Uses keycodes only to choose a sample: Space, Return, Backspace, or generic for built-in packs, and a per-key lookup for custom sounds. It does not read characters or record, save, or upload typed content. Only imported audio files and the key-to-sound assignment table are written to disk |
| CLI / URL scheme | No additional permission | Accepts local `magickey://` commands through LaunchServices; it opens no port, keeps no socket, and accepts no remote input |
| Update checks | Calls the GitHub Releases API once at launch and at most once every 24 hours afterward | Sends a User-Agent containing only the app name and version, with no device identifier or usage data |

MagicKey does not record audio, write audio to disk, upload sound, include telemetry, or send crash reports. Turning off automatic update checks stops automatic network access; clicking **Check for Updates** still contacts GitHub.

The two optional permissions are located at:

~~~text
System Settings → Privacy & Security → System Audio Recording  # Audio Beat
System Settings → Privacy & Security → Input Monitoring        # Keyboard sounds
~~~

Input Monitoring grants the technical ability to observe key events; macOS does not offer a narrower permission. MagicKey limits its use to virtual keycodes for selecting samples. It does not read characters, write keystrokes to disk, or send them over the network. Leave keyboard sounds disabled if you do not want to grant this permission; all other features remain available.

## How it works

MagicKey loads `CoreBrightness.framework` at runtime and uses `KeyboardBrightnessClient` to read and write the built-in keyboard's global `0...255` brightness value. It does not statically link the private framework; it uses `dlopen` and selector checks, then reports **Unsupported** in the UI instead of crashing when the interface is unavailable. Because this is a private interface, a future macOS update may still change its behavior.

`StateGuard` manages takeover. It saves the original state before an effect starts, pauses ambient-light adjustment and idle dimming while MagicKey is active, and restores the previous settings when it stops. This requires no `root` access.

MagicKey cannot be distributed through the Mac App Store because it uses a private system interface.

## FAQ

### Why can't Key Pulse spread outward from the key I press?

The hardware exposes only one global brightness value and no per-key lighting channels. The backlight effect also does not read the specific key pressed, so Key Pulse can only change the whole keyboard at once.

### Why does Audio Beat need System Audio Recording permission?

Audio Beat must read the sound currently playing on the Mac to detect low-frequency energy and beats. It does not use the microphone or save or transmit audio.

### Why can I sometimes see brightness steps at low levels?

Keyboard brightness is an 8-bit control value: `0...255`, giving 256 discrete levels. At 60 fps, rendering is already close to this quantization limit; raising the minimum brightness is usually more effective than raising the frame rate. See [DESIGN.md](DESIGN.md) for measurements.

### Why isn't MagicKey on the Mac App Store?

The App Store does not allow the private `CoreBrightness` interface that MagicKey depends on. The project must be distributed as an independent build or, in the future, as a signed and notarized release.

## Development

The project does not use SwiftPM. It compiles with `swiftc` and assembles the `.app` bundle through a Makefile, with no third-party runtime dependencies.

~~~bash
make -C app          # Release build
make -C app debug    # Build with debug information
make -C app run      # Run in Terminal and view logs
make -C app clean    # Remove build output
~~~

Repository layout:

~~~text
Core/       Driver, state management, effects, and audio/key-pulse sources
app/        SwiftUI menu bar app, resources, and build scripts
tools/      Effect analysis and power measurement tools
DESIGN.md   Architecture, hardware measurements, and design constraints
~~~

See [tools/README.md](tools/README.md) and [tools/TESTING.md](tools/TESTING.md) for the testing and analysis tools.

## Roadmap

- Global keyboard shortcuts for changing effects
- Context automation based on the current app, time of day, or battery state
- Developer ID signing, notarization, and stable release packaging
- Continued testing of private-interface compatibility across physical devices and macOS versions

## Contributing

Issues and pull requests are welcome. Read the measured constraints in [DESIGN.md](DESIGN.md) before changing effect curves, state restoration, or hardware behavior.

## Third-party assets and acknowledgments

All keyboard sound samples come from **[kbsim](https://github.com/tplai/kbsim)** (Mechanical Keyboard Simulator, [kbs.im](https://kbs.im)) by **Thomas Lai**, released under the **MIT License**.

MagicKey includes twelve packs: `alpaca`, `blackink`, `bluealps`, `boxnavy`, `buckling`, `cream`, `holypanda`, `mxblack`, `mxbrown`, `redink`, `topre`, and `turquoise`. The sample files are distributed byte-for-byte unchanged in `MagicKey.app/Contents/Resources/Sounds/`. The thirteenth upstream pack, `mxblue`, is not included because it lacks dedicated Space, Return, and Backspace samples, which would make those keys sound the same as letters.

The original license and full source notes, including measured RMS levels and loudness-alignment factors for each pack, are bundled in the same directory as `LICENSE-kbsim.txt` and `CREDITS.md`. They are also available in [app/Resources/Sounds/CREDITS.md](app/Resources/Sounds/CREDITS.md).

Thank you to Thomas Lai for publishing these recordings under a permissive license.

## License

MagicKey is released under the [MIT License](LICENSE). Third-party asset licensing is described in [Third-party assets and acknowledgments](#third-party-assets-and-acknowledgments).
