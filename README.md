# Windrunner + WalkingPad Control

Walk on your treadmill while you play.

- **WalkingPad Control** (Windows app) — controls a Xiaomi / KingSmith WalkingPad (A1, A1 Pro and other
  "WiLink" models) over Bluetooth, and links it to your games.
- **Windrunner** (World of Warcraft addon) — an in-game walking tracker for **any** treadmill, with a little
  walking / running figure, and optional Hardcore mode.

![Windrunner figure: standing, walking, running](docs/windrunner_anim.gif)

## Download

- **[WalkingPad.zip](https://github.com/adunis/windrunner-walkingpad-/raw/main/downloads/WalkingPad.zip)** — the Windows app (build 20261106-1949)
- **[Windrunner.zip](https://github.com/adunis/windrunner-walkingpad-/raw/main/downloads/Windrunner.zip)** — the WoW addon (v2.6)

- **App:** unzip and run `WalkingPad.exe`. Windows SmartScreen may warn because it isn't signed:
  *More info → Run anyway*. Close the KS Fit / Mi Home app first — the pad accepts one connection.
- **Addon:** unzip into `World of Warcraft\_retail_\Interface\AddOns` (or `_forever_`, `_classic_era_`…),
  so you get `AddOns\Windrunner\Windrunner.toc`. Or click **Install Windrunner** in the app.

## WalkingPad Control

- Live speed, time, distance, steps; start / stop / speed; Manual / Auto / Standby.
- Pad settings: auto-mode sensitivity, max / start speed, smart start.
- Gaming, one of three:
  - **Belt follows the game** — W walks, W+Shift sprints, gamepad stick = proportional speed. With
    Windrunner in App mode, WoW decides (idle / walk / run / mounted speeds set in-game).
  - **Pad drives the game** — walk forward on the pad in Auto mode and your character walks; faster = sprint.
    In WoW your character switches walk/run to match the belt.
  - **Treadmill only** — games are ignored.
- Closing the window stops the belt and releases held keys; minimising goes to the tray.
- Lab tab: raw Bluetooth messages, for reverse engineering.

## Windrunner (WoW addon)

- Compact window: walking / running figure, time, and *"5.00 km You / 3.00 km Thrall"*.
  Right-click or **+** for controls.
- **Manual mode** — any treadmill: Start / Pause / Stop and set your belt speed.
- **App mode** — WalkingPad Control drives the belt from your character; the session starts when you move.
- **Hardcore** (Manual mode) — movement keys locked unless a session runs. Never in combat.
- **Lore messages** (on by default) — every 0.5 km a line in the spirit of Azeroth appears like a subtitle
  at the bottom of the screen, with your distance. Each class and race has its own lines — a Troll Priest
  hears Priest and Troll lines only — and 5 km milestones follow your faction. Walking and running
  distance are tracked separately. The lines are original, written in the spirit of Azeroth
  (`addon/Windrunner/Lore.lua`).
  `/wr lore` toggles them, `/wr every 1` changes the interval, `/wr testlore` previews one.
- Commands: `/wr`, `/wr history`, `/wr miles`, `/wr warn`, `/wr hardcore`, `/wr lore`, `/wr every <km>`, `/wr testlore`, `/wr sync`, `/wr debug`.
- Works on Retail, Forever and Classic clients.

## How the link works

WoW addons can't talk to other programs, so:

- **Addon → app:** Windrunner draws three tiny coloured squares in the top-left corner of the screen;
  the app reads those pixels. Run WoW in *Windowed (Fullscreen)*.
- **App → addon:** once a second the app taps F11 / F12 to send the real belt speed, and numpad `/`
  to toggle walk / run. Windrunner binds those keys itself while it's loaded.
- If WoW runs as administrator, Windows blocks the keys unless the app runs as administrator too
  (the app detects this and offers a restart).

## The Bluetooth protocol

KingSmith "WiLink": notify `fe01`, write `fe02`. Frames `F7 … CRC FD`, CRC = sum of the bytes between
start and CRC, mod 256. Status `F7 A2 00 00 00 FD`; mode `F7 A2 02 <0 auto|1 manual|2 standby>`;
speed `F7 A2 01 <km/h×10>`; start `F7 A2 04 01`; settings `F7 A6 <key> 00 <v> <v> <v> CRC FD`
(keys 1–9; the pad answers with all settings). On the A1 Pro there's no Bluetooth command for the beep
or to skip the 3-second start countdown. Built on the work of
[ph4-walkingpad](https://github.com/ph4r05/ph4-walkingpad).

## Building

Windows: run `app\build_exe.bat` (needs Python 3.12). Or run from source:
`pip install bleak aiohttp pywebview pystray pillow` then `python app\walkingpad_app.py`.
`--simulate` runs against a pretend treadmill; `--console` uses the browser instead of a window.

## Safety

Software start commands move the belt. Be on or off the belt deliberately, keep the remote within
reach, and use the pad's physical stop if anything goes wrong. Use at your own risk.

## License

MIT
