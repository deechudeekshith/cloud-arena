# Running Cloud Arena

This is the process for starting everything, in the order you actually need it.

Cloud Arena has two parts. The game, which is a Godot project in `godot/`, and
the monitor, which is a Python service in `monitor/`. One PC runs both. Phones on
the same Wi-Fi join the game and also show up in the monitor's dashboard.

There is no cloud server. The PC that hosts the room is the server.

---

## What you need

- Godot 4.7 to run the game.
- Python 3.10 or newer for the monitor.
- A phone and a PC on the same network.

The monitor needs two Python packages. Install them once:

```bash
cd /home/lokeshpapapa/Downloads/thin_client/monitor
python3 -m pip install -r requirements.txt
```

That file lists `fastapi` and `uvicorn`. Nothing else is required, and nothing
is downloaded from the internet while it runs.

---

## Step 1. Start the monitor

The monitor is the service you asked about. It records the match and serves the
dashboard.

```bash
cd /home/lokeshpapapa/Downloads/thin_client/monitor
python3 server.py
```

It prints one line and then waits:

```
CLOUD ARENA MONITOR on http://127.0.0.1:8901  db=cloud_arena_monitor.db
```

That address only works on the PC itself. If you want a phone to open the
dashboard, bind to the whole network instead:

```bash
python3 server.py --host 0.0.0.0
```

Then the phone uses `http://<pc-ip>:8901`. On this machine that is
`http://172.29.12.185:8901`.

Be aware that binding to `0.0.0.0` means anyone on that network can read the
telemetry and send commands to the game. Use it on a network you trust, and
stop the service when you are done.

### The options

`--port` changes the port. It is `8901` unless you say otherwise.

`--db` changes which SQLite file it writes to. The default is
`cloud_arena_monitor.db`, sitting next to `server.py`.

`--game-path` points at the Godot project folder. It is used to start headless
experiment runs. The default is the `godot/` folder in this repository.

`--no-auto-launch` stops the monitor from starting experiment runs by itself.

You can stop the service with Ctrl+C. It does not need to be running for the
game to work. Without it the game still plays normally, you just get no
recording and no dashboard.

---

## Step 2. Start the game host

The host is a normal Godot project. Start it from the Godot editor by opening
`godot/project.godot` and pressing Play, or from a terminal:

```bash
flatpak run org.godotengine.Godot --path /home/lokeshpapapa/Downloads/thin_client/godot
```

If your Godot is not installed through Flatpak, use whatever command normally
starts it for you.

The host opens the room menu. Choose **Create Room**. It prints a 6-digit code
and starts listening on TCP port `7777`. Discovery for phones uses UDP port
`47777`.

The PC player joins the match as well. It is not a headless dedicated server.

---

## Step 3. Join from a phone

Install the APK from `dist/cloud_arena_android.zip` on the phone. Open the app.
It should find the room on its own. If it does not, enter the 6-digit code by
hand.

Two things have to be true for this to work. The phone and the PC must be on the
same network, and the PC firewall has to allow port `7777` and UDP `47777`.

To open the dashboard from the phone, go to `http://<pc-ip>:8901` in its
browser, using the address shown above.

---

## Step 4. Approve the player

When a phone asks to join, the host does not let it straight in. It holds the
player, writes a line in the dashboard, and raises a desktop notification on the
PC.

Click the notification's **Open dashboard** button and you land on that room's
page. Press **Accept** to let the phone in, or **Reject** to send it away.

If nobody answers, the player is let in automatically after 30 seconds. Nobody
gets stuck waiting.

This approval step can be turned off in the game's Settings, under **Require
host approval**. With it off, phones join immediately as before.

---

## What gets recorded

Everything is written to `monitor/cloud_arena_monitor.db`. It is a plain SQLite
file, so you can open it with any SQLite tool. The dashboard reads from it and
shows it per room.

Each physical device gets its own row of numbers, so a phone, a browser and the
PC are never averaged into one. Anything that was not measured shows as `N/A`
rather than a guess.

Rooms also expire honestly. If the host dies without saying anything, the room is
closed after 60 seconds and marked as a host loss, instead of staying "running"
forever.

---

## Stopping

Ctrl+C stops the monitor. Closing the game window closes the room and marks the
session finished. Nothing is left running in the background.

The database is not deleted when you stop. It keeps every session you recorded
until you remove the file yourself.

---

## If something does not work

The phone cannot find the room. Check that both devices are on the same network,
that the firewall allows TCP `7777` and UDP `47777`, and that the host actually
printed a room code.

The dashboard will not open from the phone. The monitor is bound to `127.0.0.1`,
which is the PC only. Restart it with `--host 0.0.0.0`.

Telemetry from the phone goes to the wrong place. A client that talks to
`127.0.0.1` would be posting to itself, so the game works out the monitor's
address from the host it is connected to. If you overrode it, set
`CLOUD_ARENA_MONITOR` in the environment.

---

## Rebuilding the game binaries

The APK and the web build in `dist/` are produced from `godot/`. Rebuild them
after changing any game code:

```bash
cd /home/lokeshpapapa/Downloads/thin_client
flatpak run org.godotengine.Godot --headless \
  --path "$PWD/godot" \
  --export-debug "Android" "$PWD/build/cloud_arena_debug.apk"

flatpak run org.godotengine.Godot --headless \
  --path "$PWD/godot" \
  --export-release "Web" "$PWD/build/web/index.html"
```

Use full paths. Flatpak resolves relative paths against its own working
directory and will fail on `build/web` if you give it one.

The Android export needs the Android SDK, and it signs with the debug keystore
that Godot generates under `~/.android/`. That is fine for installing on your
own phone. It is not good enough for the Play Store, which wants a release
keystore you keep safe.

The web build cannot be opened by double clicking `index.html`. WebAssembly has
to be fetched over HTTP. There is a `serve.sh` in the zip for that.
