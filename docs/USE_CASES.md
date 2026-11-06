# WalkingPad Control + Windrunner — use cases

Each line is checked by a test (T-id in brackets).

## App basics
- A1 Start / Stop / speed slider control the belt directly. Stop always stops. [T-A1]
- A2 Closing the app window stops the belt, releases held game keys, quits. Minimise → tray. [T-A2]

## Gaming: "Belt follows the game"
- F1 Any game, keyboard: W → belt starts at walk speed; W+Shift → sprint speed; release Shift → walk speed;
     release W → crawl, then stop after the idle time. [T-F1]
- F2 Any game, gamepad: stick forward → proportional speed. [T-F2]
- F3 WoW + Windrunner App mode: Windrunner decides. "Belt should run" ON → belt starts (countdown) and
     tracks the speed Windrunner asks for (idle 1 / walk 3 / run 5 / mount 6). OFF → belt stops. [T-F3]
- F4 If you stop the belt yourself (app Stop, tray, pad remote) while Windrunner still wants it running,
     it stays stopped until you start moving in WoW again. [T-F4]
- F5 WoW minimised / covered: belt slows to a crawl, stops after 20 s; when WoW is back and Windrunner
     still wants it running, it starts again. [T-F5]
- F6 Windrunner switched to Manual mode: the app stops driving the belt. [T-F6]

## Gaming: "Pad drives the game"
- D1 The pad is put in Auto mode; the app's Start button starts the belt IN Auto mode (not Manual). [T-D1]
- D2 Belt ≥ "move from" speed → forward key held in the game; ≥ "sprint from" → sprint key too;
     belt slows/stops → keys released. [T-D2]
- D3 Keys only go to the game window (WoW recognised by title or Wow.exe); switching window releases them. [T-D3]
- D4 Windrunner in App mode does NOT take over the belt in this direction. [T-D4]
- D5 If the game runs as administrator and the app doesn't, the app says so and offers to restart as admin. [T-D5, Windows-only check]

## Windrunner — Manual mode (any treadmill)
- M1 Start / Pause / Resume / Stop; time and distance from the speed you set (− / +). [T-M1]
- M2 Hardcore (default on): movement keys locked unless a session is running; never in combat. [T-M2]
- M3 Warning when the character walks on foot without a running session. [T-M3]

## Windrunner — App mode (WalkingPad Control)
- W1 No session: when the character STARTS moving, a session starts and the belt is asked to run. [T-W1]
- W2 Time/distance are counted while the belt is asked to run, after a 5 s countdown allowance;
     standing still counts at the idle speed. [T-W2]
- W3 Pause → belt stops, counting stops. It stays paused while you keep moving; Resume (or stop
     moving and start again) → belt runs again. [T-W3]
- W4 Stop → session saved, belt stops. Moving again starts a new session. [T-W4]
- W5 Start button with no session → session + belt start even while standing. [T-W5]
- W6 Hardcore and the warning don't apply. [T-W6]
- W7 Speeds (idle/walk/run/mount) set in-game are what the app applies. [T-W7]
