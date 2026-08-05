# AHK Mouse Jumper

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

Both scripts are functionally equivalent — use whichever matches the AutoHotkey runtime
installed on a given machine.

## Requirements

- [AutoHotkey](https://www.autohotkey.com/) v1.1.36+ or v2.0+ (matching the script you run).
- [`hidapitester.exe`](https://github.com/todbot/hidapitester/releases) placed next to the
  script (not included in this repo — download the Windows build from its releases page).
- A Logitech (or HID++-compatible) receiver that supports multiple paired devices/channels.
  The default `ReceiverVidPid` in the scripts is `046D:C52B`; change it in the script if
  your receiver reports a different VID:PID (check with `hidapitester --list`).

## Setup

1. Clone this repo onto each PC.
2. Download `hidapitester.exe` from its [releases page](https://github.com/todbot/hidapitester/releases)
   and place it in the same folder as the script.
3. Run `mouse_jumper.ahk` (or `mouse_jumper_v2.ahk`) — use the first-run OSD to pick this
   machine's `Position` (TOP/BOTTOM) and target `Channel`.
4. Repeat on the other PC with the opposite `Position`.

### Run at startup

1. `Win + R` → `shell:startup` → Enter, to open your personal Startup folder.
2. Right-click inside it → **New → Shortcut**, and point it at the script for this machine.
3. It will now launch automatically at every login.

For a system-level (pre-login) start instead, use Task Scheduler with an "At startup"
trigger rather than the Startup folder.
