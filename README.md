# Siege Profile Manager

A Logitech G HUB Lua script (`siege_profile_manager.lua`) plus an AutoHotkey v2 overlay
(`SiegeOverlay.ahk`) for Rainbow Six Siege.

> **Keep this repository private and use it for training-range / offline testing only.**
> The recoil part is an anti-recoil macro. Using it online breaks Siege's rules and can get an
> account banned.

## Files

| File | What it is |
|---|---|
| `siege_profile_manager.lua` | The G HUB script: operator picker (click detection on the 7x7 grid), loadout manager, recoil macro with guided tuning, and the state exporter for the overlay. |
| `SiegeOverlay.ahk` | AutoHotkey v2 overlay (borderless, click-through, always on top). Windows only. |

## Setup (Windows)

1. G HUB: open the profile's scripting editor, open (or create) a script, paste the whole of
   `siege_profile_manager.lua`, save.
2. Install AutoHotkey v2 and run `SiegeOverlay.ahk`. Close DebugView or any other debug monitor
   first: only one program can receive debug output.
3. Press `RALT + left click` once so the script sends its state to the overlay.

The overlay receives state through `OutputDebugMessage` (Windows debug output). The G HUB Lua
sandbox has no file access and its console is not logged to disk, so there is no file or OCR
involved.

## Keys (all configurable in `CONFIG.input` in the Lua)

Only modifiers and mouse buttons can be read by G HUB Lua (letter keys are impossible).
Right/middle click are event numbers 2 and 3 (`OnEvent` numbering).

| Keys | Action |
|---|---|
| `RSHIFT + left click` | Detect the operator under the cursor |
| `RCTRL + MB5 / MB4` | Next / previous operator |
| `LCTRL + MB5 / MB4` | Next / previous favorite |
| `RCTRL + LMB` | Favorite on/off |
| `LCTRL + LMB` | Attackers / defenders page |
| `LALT + MB5 / MB4` | Next primary / next secondary |
| `LALT + LMB` | Next grip |
| `LSHIFT + MB5 / MB4` | Next scope / next barrel |
| `RALT + MB5` | System on/off |
| `RALT + MB4` | Debug on/off (shows every event under `[RAW]`) |
| `RALT + LMB` | Redraw / resend state to the overlay |
| `RSHIFT + MB4` | Calibrate the grid: start, then set each corner |
| `RSHIFT + MB5` | Cancel calibration / reset it to the preset |
| `LSHIFT + LMB` | Recoil tune on/off |
| `1` / `2` (in Siege) | Overlay switches the manager to primary / secondary (via ScrollLock) |
| `F8` / `F9` / `F10` | Overlay: hotkey list / show-hide / copy tuned profiles |

## Recoil tuning (training range)

1. Pick the exact loadout (barrel and grip must match the game: `LSHIFT+MB4`, `LALT+LMB`).
2. `LSHIFT + LMB`, then hold ADS + fire at a wall.
3. Step 1 vertical: holes still climb, `MB5`; holes sink, `MB4`. Step 2 sideways: drift left
   `MB5`, drift right `MB4`. Step 3 end of spray, same idea.
4. `LALT+MB5` next step (finish on step 3), `LALT+MB4` back, `LSHIFT+MB4` reset.
5. The overlay copies tuned profiles to the clipboard (or `F10`). Paste into `RECOIL_PROFILES`.

Profiles are stored per exact loadout: `"WEAPON:BARREL:GRIP"`.

## Editing on a Mac

You can edit both files anywhere. Running them needs Windows: AutoHotkey is Windows only, and the
G HUB script depends on the G HUB scripting API. Copy the edited Lua back into G HUB.
