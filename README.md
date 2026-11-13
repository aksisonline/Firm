# TrackpadPen

A tiny macOS menu-bar utility that turns your Force Touch trackpad into a **pressure-sensitive pen** for Photoshop, Affinity, Blender, Krita and anything else that reads macOS tablet events — globally, with no per-app plugins.

It sits alongside the normal mouse/trackpad driver and only *adds* data: every left-button mouse event is annotated as a tablet-pen event carrying live trackpad force.

## How it works

| Step | What happens |
|---|---|
| 1 | `MultitouchReader` streams per-finger force (≈ grams) from the private `MultitouchSupport.framework` at ~100 Hz, loaded via `dlopen`/`dlsym`. This is the same source [TrackWeight](https://github.com/KrishKrosh/TrackWeight) uses. |
| 2 | A session-level `CGEventTap` (after WindowServer has moved the cursor, before apps see the event) rewrites each left mouse down / drag / up into a tablet-point event (`kCGEventMouseSubtypeTabletPoint`) carrying that force, normalised to 0…1, in `kCGMouseEventPressure` and `kCGTabletEventPointPressure`. |
| 3 | A tablet **proximity-enter** event is posted before each stroke and **proximity-exit** after it, so apps switch their pointer to *pen*. |
| 4 | Optionally, Force Touch's own stage-2 events are swallowed, and/or the trackpad's hardware force response is switched off, so Look Up / Quick Look can't fire mid-stroke. |

> The tap deliberately runs at the *annotated session* level. Tapping at HID level and adding absolute tablet coordinates makes WindowServer treat the input as a tablet and freezes the cursor.

## Build & run

Requires Xcode command line tools (Swift 5.9+) and macOS 13+.

```sh
make run          # builds, bundles build/TrackpadPen.app, and opens it
```

On first enable, macOS asks for **Accessibility** and **Input Monitoring**. Grant both to `TrackpadPen.app`, then flip the toggle again. Rebuilding changes the ad-hoc signature, so you may need to remove and re-add the app in System Settings → Privacy & Security.

## Controls

- **Enable pen pressure** — starts/stops the multitouch stream and the event tap.
- **Suppress Force Click (events)** — swallows stage-2 force-click events.
- **Disable trackpad force response (hardware, experimental)** — calls `MTDeviceSetSystemForceResponseEnabled(false)`. Restored automatically on disable/quit.
- **Max force** — grams that map to full pressure (default 200 g; a firm press reads roughly 100–130 g).
- **Deadzone** — grams below which pressure is 0, so a resting finger doesn't register.
- **Curve (γ)** — `< 1` makes light touches heavier, `> 1` lighter.
- **Minimum** — pressure floor while the button is down so the first dab is visible.

## Known limits

- Uses a **private, undocumented** framework. It can change between macOS releases and can't ship on the Mac App Store.
- Pressure is the strongest single touch, not a per-finger mapping.
- Tilt and rotation are reported as 0.
- Only the left button is converted; right-click and gestures pass through untouched.
- Some apps may key off other tablet-proximity fields; if one ignores pressure, open an issue.

## Layout

```
Sources/MultitouchShim/    C header with the MTTouch struct layout
Sources/TrackpadPen/
  MultitouchReader.swift   dlopen'd MultitouchSupport force stream
  PressureEngine.swift     pressure mapping, event tap, tablet-event synthesis
  Permissions.swift        Accessibility / Input Monitoring checks
  TrackpadPenApp.swift     MenuBarExtra entry point
  ContentView.swift        settings popover + live pressure meter
Resources/Info.plist       LSUIElement bundle metadata
Makefile                   swift build → .app bundle → ad-hoc codesign
```

## Credits

Multitouch access approach from [TrackWeight](https://github.com/KrishKrosh/TrackWeight) and [OpenMultitouchSupport](https://github.com/KrishKrosh/OpenMultitouchSupport).

## License

MIT
