# AHK Mouse Jumper

[![Lint](https://github.com/vmynick/ahk-mouse-jumper/actions/workflows/lint.yml/badge.svg)](https://github.com/vmynick/ahk-mouse-jumper/actions/workflows/lint.yml)

A tiny AutoHotkey utility that turns mouse movement into a KVM-style switch: push the
cursor off the top or bottom edge of the screen and it flips a shared Logitech HID++
receiver over to another paired device (another PC), so your mouse (and, if the
receiver/keyboard are paired the same way, your keyboard) "jumps" to the other machine.

Two PCs run this script side by side — one configured as the **TOP** screen, the other
as the **BOTTOM** screen — so moving the cursor past the shared edge switches control
seamlessly, without any extra hardware KVM box.

## How it works

1. The script polls the mouse position every 30ms.
2. Depending on this machine's configured `Position`:
   - `TOP` → switching triggers when the cursor reaches the **bottom** edge of the screen.
   - `BOTTOM` → switching triggers when the cursor reaches the **top** edge of the screen.
3. The cursor must **dwell** at the edge for ~567ms (shown as a progress-bar OSD) before
   the switch fires — this avoids accidental switches when just brushing the edge.
4. On switch, it sends a HID++ "set channel" output report to the receiver via
   [`hidapitester`](https://github.com/todbot/hidapitester), targeting the configured
   `TargetChannel`, and re-centers the cursor under the on-screen confirmation.

## Channels & controls

The receiver can have multiple devices/computers paired to it; each paired slot is a
**channel**. This script can target channel **1**, **2**, or **3**.

### First-run interactive setup

Every time the script starts, it shows an OSD for a few seconds so you can (re)configure it:

| Step | Prompt | Keys | Time window |
|---|---|---|---|
| 1 | `Mode: <X> \| Target: Ch <N> — Press [SPACE] to change settings` | `Space` | 8s |
| 2 | `Press [T] for TOP or [B] for BOTTOM` | `T` / `B` | 15s |
| 3 | `Press [1], [2] or [3] for Channel` | `1` / `2` / `3` | 15s |

- If you don't press `Space` in time, the script just starts with the last saved settings.
- While a setup prompt is active, the relevant keys (`Space`, `T`, `B`, `1`, `2`, `3`) are
  **captured** and will not be typed into whatever window has focus.
- Each choice is written to `settings.ini` immediately, so it survives restarts.

### Config file (`settings.ini`)

```ini
[Settings]
Position=TOP
TargetChannel=1
```

- `Position`: `TOP` or `BOTTOM` — which edge of the screen triggers a switch.
- `TargetChannel`: `0`, `1`, or `2` — zero-based, corresponds to channel 1, 2, 3 shown in the OSD.

A template is provided as [`settings.ini.example`](settings.ini.example); copy it to
`settings.ini` next to the script if you want to pre-seed values instead of using the
first-run wizard.

## Files

| File | AutoHotkey version | Notes |
|---|---|---|
| [`mouse_jumper.ahk`](mouse_jumper.ahk) | v1.1 | Main script |
| [`mouse_jumper_v2.ahk`](mouse_jumper_v2.ahk) | v2.0 | Same behavior, ported to AHK v2 syntax, for machines running AutoHotkey v2 |
| [`mouse_jumper_pro.ahk`](mouse_jumper_pro.ahk) | v1.1 | Extended build — tray menu, hotkeys, left/right edges, multi-monitor, logging. See [Mouse Jumper Pro](#mouse-jumper-pro) |
| [`find_channel_codes.ps1`](find_channel_codes.ps1) | — | PowerShell helper to discover the HID++ codes for *your* mouse/receiver |
| [`setup.ps1`](setup.ps1) | — | Optional one-time setup helper (AutoHotkey check, `hidapitester.exe` download, Startup shortcut) |

`mouse_jumper.ahk` and `mouse_jumper_v2.ahk` are functionally equivalent — use whichever
matches the AutoHotkey runtime installed on a given machine. `mouse_jumper_pro.ahk` is an
optional, more featureful alternative to `mouse_jumper.ahk` (see below); it's independent
of the other two and keeps its own settings file, so trying it never affects them.

## Mouse Jumper Pro

`mouse_jumper_pro.ahk` is the same idea with some extra power-user features layered on
top. It reads/writes its own `settings_pro.ini` (never `settings.ini`), so it's safe to
try alongside an existing `mouse_jumper.ahk` setup without disturbing it.

**Extra features:**
- **System tray menu** — right-click the tray icon to reconfigure, pause/resume, switch
  now, open the script folder, reload, or exit.
- **Hotkeys**, work anytime (not just at startup):
  - `Ctrl+Alt+P` — pause/resume edge-switching (useful when dragging a window across the
    trigger edge and you don't want an accidental switch).
  - `Ctrl+Alt+S` — switch immediately, without needing to touch the screen edge.
  - `Ctrl+Alt+R` — re-run the interactive setup wizard on demand, without restarting the
    script.
- **Left/right edges**, not just top/bottom, for side-by-side monitor arrangements — the
  setup wizard now asks `[T]op [B]ottom [L]eft [R]ight`.
- **Per-monitor edge detection** — watches a specific monitor's bounds instead of the
  whole virtual desktop, which matters on multi-monitor setups (the wizard adds a monitor
  picker step automatically if it detects more than one).
- **Startup dependency checks** — warns via a tray notification if `hidapitester.exe` is
  missing, or if the configured `ReceiverVidPid` isn't detected.
- **Optional logging** — set `EnableLogging=1` in `settings_pro.ini` to log switches and
  warnings to `mouse_jumper_pro.log`.

## Requirements

- [AutoHotkey](https://www.autohotkey.com/) v1.1.36+ or v2.0+ (matching the script you run).
- [`hidapitester.exe`](https://github.com/todbot/hidapitester/releases) placed next to the
  script (not included in this repo — download the Windows build from its releases page).
- A Logitech (or HID++-compatible) mouse + receiver that supports multiple paired
  hosts/channels (e.g. Logitech's "Easy-Switch"). Tested on a **Logitech MX Master 3**;
  other models will likely need different HID++ codes — see
  [Adapting to a different mouse or receiver](#adapting-to-a-different-mouse-or-receiver).
  The default `ReceiverVidPid` in the scripts is `046D:C52B`; change it in the script if
  your receiver reports a different VID:PID (check with `hidapitester --list`).

## Adapting to a different mouse or receiver

This project was built and tested against a **Logitech MX Master 3** paired to a
Logitech receiver at VID:PID `046D:C52B`. The channel-switch command it sends is a
vendor-specific HID++ 2.0 request:

```
0x10, <deviceIndex>, <featureIndex>, 0x1<swID>, <channel>, 0x00, 0x00
```

`deviceIndex` (which paired device slot the receiver assigned to your mouse) and
`featureIndex` (where the "Change Host" feature landed in that device's HID++ feature
table) are **not fixed values** — they depend on your specific mouse/receiver pairing
and firmware, and will very likely be different on your hardware. That's why the byte
sequences hardcoded in `SwitchChannel()` in this repo's scripts may not work as-is on
a different mouse, even one that supports the same multi-host "Easy-Switch" channels.

To find *your* values instead of sniffing USB traffic by hand, run the included helper:

```powershell
.\find_channel_codes.ps1
```

It runs fully autonomously, no manual input required:
1. Lists the HID collections it can see as a table.
2. Scans every device index, auto-detecting which (usage, HID++ report length)
   combination gets real replies out of *that* index — a single `-UsagePage` often has
   several collections (e.g. short 7-byte vs. long 20-byte HID++ reports), and it can
   vary even between device indices on the same receiver, not just between receivers.
   Each responding index is checked for the HID++ features known to relate to host
   switching (`CHANGE_HOST`, `HOSTS_INFO`, and a couple of related pairing features).
3. Autonomously tries the plausible function numbers, report lengths, and channels
   against each candidate found, firing a real "switch host" command each time. Success
   is detected by the device going silent on this receiver right after a command — i.e.
   it actually jumped to another host — so there's nothing to eyeball. The moment that
   happens, it stops, prints the exact bytes to use in `SwitchChannel()`, and — if it
   finds `mouse_jumper.ahk` / `mouse_jumper_v2.ahk` next to it — points out the exact
   file and line to change, with the old and new byte sequence shown side by side.

Because it really fires host-switch commands, if it succeeds **your mouse will jump off
this PC during the test** — that's the proof the codes work. Use the mouse's physical
Easy-Switch button (or just wait) to bring it back, or run the script again on the other
machine once the mouse arrives there.

It only ever sends commands to that known, curated feature list — never to arbitrary
HID++ features it finds along the way, since some (device reset, DFU mode, ...) are
destructive and guessing at those isn't safe to automate. If nothing on the list is
found, it prints the full feature table of every responding device instead, so you can
identify the right one yourself.

By default it only prints what it found and the final result. Pass `-Verbose` to also
see every (usage, length) combination and every function/channel attempt it tried along
the way:

```powershell
.\find_channel_codes.ps1 -Verbose
```

By default it only *prints* the bytes to change and where to change them — it never
edits your files unless you pass `-Apply`, in which case it patches the matching
`.ahk` file(s) in place (making a one-time `.bak` backup of each first):

```powershell
.\find_channel_codes.ps1 -Apply
```

It needs `hidapitester.exe` next to it, same as the main scripts.

## Setup

1. Clone this repo onto each PC.
2. Run [`setup.ps1`](setup.ps1) to check for AutoHotkey, download `hidapitester.exe`
   automatically, and optionally create a Startup shortcut:
   ```powershell
   .\setup.ps1 -Script mouse_jumper.ahk
   ```
   (or do it by hand: download `hidapitester.exe` from its
   [releases page](https://github.com/todbot/hidapitester/releases) and place it in the
   same folder as the script.)
3. Run `mouse_jumper.ahk` (or `mouse_jumper_v2.ahk` / `mouse_jumper_pro.ahk`) — use the
   first-run OSD to pick this machine's `Position` (TOP/BOTTOM) and target `Channel`.
4. Repeat on the other PC with the opposite `Position`.

### Run at startup

`setup.ps1 -Script <name>.ahk` (see [Setup](#setup) above) does this for you, asking
first. To do it by hand instead:

1. `Win + R` → `shell:startup` → Enter, to open your personal Startup folder.
2. Right-click inside it → **New → Shortcut**, and point it at the script for this machine.
3. It will now launch automatically at every login.

For a system-level (pre-login) start instead, use Task Scheduler with an "At startup"
trigger rather than the Startup folder.

## License

[MIT](LICENSE)
