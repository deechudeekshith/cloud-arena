# Cloud Arena

A 3D arena shooter you play on a phone against bots, with the match hosted from a
PC on the same Wi-Fi. One person runs the game on the PC and becomes the room
host. Phones join with a 6-digit code. There is no cloud server and no account.
Everything stays on your own machines.

A second piece, the monitor, records how each match ran and shows it in a
browser dashboard. It can also send a few commands back to the game, like
starting or stopping a match, or approving a phone that wants to join.

## What is in here

| Folder | What it is |
|---|---|
| `godot/` | The game. Godot 4.7, GDScript. One human player plus bots, 4v4, 3-minute matches. |
| `monitor/` | The recording service and dashboard. Python, FastAPI, SQLite. |
| `docs/` | How to run all of it. Start with `docs/RUNNING.md`. |
| `src/` | An old 2D top-down prototype. Frozen, kept only as a rules reference. |
| `build/`, `dist/` | Build output. Not in git. |

## Requirements

Godot 4.7 for the game. Python 3.10 or newer for the monitor. A phone and a PC on
the same network to play against each other.

## Quick start

Install the monitor's two dependencies, then read the manual:

```bash
cd monitor
python3 -m pip install -r requirements.txt
```

`docs/RUNNING.md` walks through the whole process in order. The short version:

1. Start the monitor: `python3 monitor/server.py`
2. Start the game from `godot/project.godot` and create a room.
3. Install the APK on a phone and join with the room code.
4. Approve the phone from the dashboard, or let it through after 30 seconds.

The monitor is optional. Without it the game still plays normally, you just get
no recording and no dashboard.

## Controls

Mouse and keyboard on the PC. On screen there is a virtual stick to move, a
fire button, an ADS button, and a pause button.

ADS is hold to aim by default. Turn on **Scope toggle** in Settings to tap once
and stay scoped. **Auto-aim** gently eases your aim toward an enemy already
inside a narrow cone, and only while you are scoped or firing.

The on-screen buttons can be moved. Go to Settings, then **Customize Layout**,
and drag them wherever you want.

## Networking

The host listens on TCP `7777`. Phones find it over UDP `47777`. The monitor
serves on TCP `8901`. Both the firewall and the network have to allow the first
two for a phone to join.

Game traffic and monitor traffic are kept separate. Telemetry is never counted
in the game's bandwidth figures.

## Not in scope

There is no public internet server. Everything is local network only. Reaching
players outside your own Wi-Fi would need a relay or a cloud host, which is a
different project.

There is no Play Store build. The APK is signed with the debug keystore, which is
fine for installing on your own phone and not valid for the store.
