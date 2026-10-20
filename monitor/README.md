# CLOUD ARENA — RESEARCH MONITOR

Local, offline-first research/monitoring system for the Cloud Arena game.
The game is **not modified** in any behavioural way: this is an additive
telemetry + control channel around the existing Godot 4 project.

```
┌──────────────┐   HTTP telemetry + command ACK   ┌──────────────────┐
│ Cloud Arena  │ ───────────────────────────────► │  monitor service │
│ (Godot 4.7)  │ ◄─────────────────────────────── │  FastAPI+SQLite  │
└──────────────┘        queued commands (poll)    └────────┬─────────┘
                                                            │ WebSocket
                                                            ▼
                                                 browser dashboard
```

Game traffic (players) and monitoring traffic (telemetry) are **separate
channels and separately measured**; monitoring bytes are never included in
the game's bandwidth figures.

---

## 0. The room/session model (the default view)

The dashboard is **room-centric**. Everything hangs off a *room*, not off a
single global "current match":

* A **room** is a 6-digit code the PC host opens. Several can be live at once.
* A **session** is one visit to that room. It opens with the first device
  (the host, before any match) and closes when the last device leaves, so
  recording spans **pre-match lobby → match → lobby**, not just the match.
* A **device** is one physical client, identified by a stable
  `<platform>-<pid>-<run>` id, so a phone, a browser and the PC each get their
  own FPS / ping / CPU / upload series instead of being averaged together.

The ROOMS tab lists every room with live player/device counts, match status,
session length and optimization mode. `#room/<code>` deep-links straight to a
room. Cards labelled **PC CPU / PC RAM / PC UPLOAD / PC DOWNLOAD** are the
**host only**; graphs labelled *(all devices)* plot every device so they can be
compared.

A session is closed honestly:

| Situation | Result |
|---|---|
| Last device sends `ROOM_LEFT` | session closed, room `EMPTY` |
| Host dies with no event (crash/kill) | closed after 60 s without a heartbeat, status `timeout: host lost`, match shown as **TIMEOUT (host lost)** |
| A duplicate/late `ROOM_CREATED` within 90 s | the newest session is re-opened (reconnect race) — older history is never rewritten |

Never-fabricated rules: an unterminated match is never shown as `RUNNING`
forever, unavailable values render `N/A`, and the room list never invents a
room that no game reported.

### Mobile / browser clients reporting telemetry

A client that hardcoded `127.0.0.1` would post its telemetry to *itself*, so
`MonitorLink.resolve_base_url()` picks the monitor host in this order:

1. explicit override (CLI / config),
2. `CLOUD_ARENA_MONITOR` environment variable,
3. **the room host it actually connected to** (the monitor runs on the same PC
   as the host, one port over from the game),
4. loopback, for single-machine desktop runs.

To watch a phone on the LAN, expose the service and use the PC's LAN IP:

```bash
python3 server.py --host 0.0.0.0        # opt-in; prints a LAN exposure warning
```

CORS is scoped to loopback + RFC1918 origins only, so a random website cannot
queue commands for a live session; the Web build's cross-origin telemetry POST
is allowed.

---

## 1. Launch

```bash
cd monitor
python3 server.py                       # default port 8901
python3 server.py --port 9000           # custom port
python3 server.py --no-auto-launch      # never spawn the game yourself
python3 server.py --game-path /path/to/thin_client/godot
```

Open **http://127.0.0.1:8901** in a browser. No internet, no API keys,
no cloud account, no CDN assets.

Requirements: Python 3.9+ with `fastapi` and `uvicorn` (`pip install fastapi uvicorn`).
Database: `monitor/cloud_arena_monitor.db` (SQLite, created on first run).

## 2. Game telemetry (additive, optional)

`scripts/net/MonitorLink.gd` posts a compact telemetry packet to
`http://127.0.0.1:8901/api/ingest` once per second and polls
`/api/commands` every 2 s. If the service is not running the game is
completely unaffected (failures are silent + retried).

Start the normal game as usual, or let the monitor launch headless runs.

## 3. Experiment workflow (repeatable)

1. **EXPERIMENTS → NEW EXPERIMENT** — set name, map, **map seed**,
   players, bots, duration, bandwidth, latency, loss.
2. **START BASELINE** → runs the `NORMAL` codec (full-state snapshots).
3. **START OPTIMIZED** → runs the `OPTIMIZED` pipeline with the experiment's
   flag set, same seed/players/duration.
4. **COMPARE** → side-by-side numbers, deltas, 6 overlay graphs, and a
   conclusion generated *from the stored samples only*.

Both runs auto-launch a headless Godot process (log:
`monitor/run_<exp>_<side>.log`). To run them by hand instead:

```bash
flatpak run org.godotengine.Godot --headless \
  --path ../godot --script res://tests/ExperimentRun.gd -- \
  --mode=OPTIMIZED --seed=777 --dur=180 --exp=exp001 --mon=8901 \
  --rate=20 --budget=0 --flags=delta,dedup,compression,priority,partial
```

Repeatability: the runner fixes the map seed, combatant count, bot count,
duration and update rate, so the only intended difference between the two
sides is the communication pipeline. The COMPARE page still re-checks
compatibility (map, seed, players, bots, duration, network) and prints
**MATCH COMPATIBLE** or **NOT COMPARABLE: <reason>**.

## 4. Ablation testing

EXPERIMENTS → ABLATION PRESETS runs a single optimized match with a
specific flag combination (Delta only, Dedup only, Compression only,
Priority only, Δ+C, Δ+D+C, Full). Every run is stored as its own
experiment, so components can be attributed only where the measurements
support it.

## 5. Automated benchmark matrix

EXPERIMENTS → AUTOMATED BENCHMARK. Choose bandwidths and modes; the
service then runs the matrix **sequentially** (never unbounded), with
START/STOP. Each cell is its own experiment, so the matrix yields
data-reduction / RTT / FPS / CPU-vs-bandwidth curves.

## 6. Optimization controls (these really change behaviour)

OPTIMIZATION page:

| Control | Effect in the game |
|---|---|
| Delta ON/OFF | OFF → every snapshot is a full state |
| Dedup ON/OFF | OFF → identical payloads are never collapsed |
| Compression ON/OFF + algorithm | OFF → raw wrap; algorithm = FastLZ/Deflate/ZSTD/GZIP |
| Priority ON/OFF | OFF → MEDIUM fields ride every packet |
| Partial ON/OFF | OFF → unchanged players resend full records |
| Medium cadence / full heal | scheduler intervals (1–60 / 1–600) |
| Update rate 5–60 Hz | host snapshot rate |
| Bandwidth budget | host **token bucket**; over-budget snapshots are dropped and counted |

Every control is validated (server + client) and shows
**COMMAND SENT → COMMAND APPLIED / FAILED** from the game's own ACK.
Nothing is faked: if the game rejects a value, the dashboard says FAILED.

## 7. Network simulation

NETWORK page stores bandwidth/latency/jitter/loss. Bandwidth is also
pushed to the live game budget. Latency/jitter/loss are applied to experiment runs by the in-game
`NetSim` conditioner (latency + jitter + loss + link bandwidth, validated
and rejected when out of range) and are labelled **● SIMULATED NETWORK**;
matches measured under simulation are stored with `network_mode = simulated`
so simulated and real statistics are never mixed without a label.

Measured example: `--lat=80 --jit=20 --loss=2` produced 11 dropped packets
out of 460 (2.39 %) — the configured 2 % within sampling variance.

## 8. "Someone is knocking" notifications (host PC)

When the PC is hosting and a client completes the WebSocket handshake and asks
to join, the **host machine** alerts you immediately — you do not have to be
looking at the game window:

* a desktop notification via `notify-send` (libnotify), falling back to
  `osascript` on macOS and a tray balloon on Windows,
* a terminal beep,
* an in-game cyan banner: `<name> joined · room <code> · <n>/<max>`.

It is debounced (8 s) because a phone retries the WebSocket connect several
times per attempt and would otherwise fire the same alert repeatedly, and it
never fires on the joining client itself — only on the host.

Verified end-to-end: a real second process joined a real room and produced
`{"sent": true, "player": "Player", "code": "855676"}`. `notify-send` returns 0
and a session notification daemon is present, so the popup really appears.
Toggle with **Settings → Join alerts** (persisted in `GameSettings`).

## 9. Data quality rules

* Every sample carries timestamp, match_id, experiment_id, mode, source.
* Unavailable platform values (e.g. CPU on non-Linux) are stored as `-1`
  and rendered **N/A**, never invented.
* `REAL` / `SIMULATED` labels come from the run's own configuration.
* A match whose game vanished without `MATCH_ENDED` is finalized from
  stored samples and logged as `timeout finalize`, never as a clean finish.

## 10. Measured results (2 real peers, seed 4242, 8 combatants, 180 s)

`exp025` — MATCH COMPATIBLE, 357 samples per side, one real WebSocket guest
attached to each host (`peers: 1`).

| | BASELINE / NORMAL | OPTIMIZED | change |
|---|---|---|---|
| Data transferred | 13 900.9 KB | 1 708.7 KB | **-87.7 %** |
| Avg upload | 76.7 KB/s | 9.7 KB/s | -87.3 % |
| Avg RTT | 9.15 ms | 7.91 ms | -13.5 % |
| Avg ping | 9.15 ms | 7.91 ms | -13.5 % |
| Avg FPS | 144.9 | 144.9 | +0.0 % |
| Avg CPU | 3.06 % | 3.12 % | +1.7 % |
| Avg RAM | 169 MB | 169 MB | +0.3 % |
| Packet loss | 0.00 % | 0.00 % | N/A (0 baseline) |
| Compression ratio | 1.000 | 0.371 | -62.9 % |

Caveat: the peer is a second process on the SAME machine (127.0.0.1), so the
~8-9 ms "RTT" is mostly Godot RPC + scheduling overhead, not propagation. The
measured -13.5 % RTT means the optimized pipeline returns slightly faster on
loopback (smaller payloads to serialise); on a real LAN/WAN the effect would be
dominated by actual network conditions. Repeat with a phone peer to measure
real link latency.

## 11. Export (offline)

EXPORT page (or REST): experiment and match exports as **JSON** and **CSV**
including raw samples, summary, configuration and the comparison.

```bash
curl -OJ 'http://127.0.0.1:8901/api/export/exp001?format=csv'
curl -OJ 'http://127.0.0.1:8901/api/export-match/<match_id>?format=json'
```

## 12. REST / WebSocket reference

| Endpoint | Purpose |
|---|---|
| `POST /api/ingest` | game telemetry ingest |
| `GET /api/commands` | game polls queued commands |
| `POST /api/ack` | game command result |
| `POST /api/send-command` | dashboard queues a command (validated) |
| `GET /api/status` `/api/live` | connection + live snapshot |
| `GET /api/rooms` | every room + open session summary |
| `GET /api/rooms/{code}` | room, session, devices, events, samples |
| `GET /api/rooms/{code}/samples` | per-device time series for that room |
| `GET /api/sessions` | finished + open sessions (history) |
| `GET /api/sessions/{id}` | replay payload: samples, events, report |
| `GET /api/sessions/compare?a&b` | two sessions side by side |
| `GET /api/sessions/export/{id}?format=csv\|json` | session export |
| `GET /api/devices/{id}` | per-device detail for a session |
| `GET /api/peer-status` | headless peer/room-code status |
| `GET /api/matches` `/api/samples` | match history |
| `GET/POST /api/experiments`, `…/start`, `…/stop` | experiment control |
| `GET /api/compare?a&b`, `/api/exp-compare/{id}` | comparison |
| `GET/POST /api/config/opt`, `/api/config/net` | stored configurations |
| `POST /api/benchmark`, `/api/benchmark/stop` | benchmark matrix |
| `GET /api/export/{exp}`, `/api/export-match/{mid}` | JSON/CSV export |
| `WS /ws` | live stream (1 Hz) |

## 13. Layout

```
monitor/
  server.py                 FastAPI + SQLite + WebSocket service
  static/index.html         room-centric dashboard markup
  static/style.css
  static/app.js             rooms, devices, charts, controls, history, replay
  cloud_arena_monitor.db    SQLite database (auto-created)
  run_<exp>_<side>.log      headless game run logs
../godot/scripts/net/MonitorLink.gd        telemetry + command client
../godot/scripts/net/NetTransport.gd      remembers the joined host address
../godot/tests/ExperimentRun.gd            repeatable headless run
../godot/tests/MonitorUrlTest.gd           monitor-URL resolution checks
```

## 14. Known limitations (measured, not assumed)

* The automated peer is a second process on the **same** machine, so the
  ~8–12 ms "RTT" is Godot RPC + scheduling overhead, not propagation. A phone
  on a real LAN is still the honest way to measure link latency.
* An Android SDK **is** installed at `~/Android/Sdk` (adb, build-tools 36,
  platform-tools) and the debug APK builds and is signed, but there is no
  connected device and no emulator system image, so no on-device run has been
  performed. The Web build was booted in headless Chromium and reached the
  game; an automated canvas-UI join into a live room was not completed.
* `DuelSim`'s "bot can kill" assertion is flaky (~1 in 3 runs the bot fails
  to land a kill inside the 40 s window). It is a bot-lethality variance issue,
  not a networking one.
* Simulated latency/jitter/loss shape the host's outgoing snapshot path; the
  separate ping/RTT probe is not conditioned, so reported RTT does not include
  simulated latency. Bandwidth budget and packet loss do affect both.

