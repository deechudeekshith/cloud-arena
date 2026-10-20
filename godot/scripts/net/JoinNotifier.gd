class_name JoinNotifier
extends RefCounted

## Desktop notification + sound when someone asks to join the PC's room.
##
## Runs entirely on the HOST PC. It shells out to `notify-send` (libnotify)
## when available and always shows an in-game banner, so the feature works
## with or without a desktop notification daemon.
##
## Design notes:
##  - fire-and-forget: `OS.create_process` never blocks the game loop, and a
##    missing notifier must never break joining.
##  - debounced, because a phone retries the WebSocket connect and would
##    otherwise fire the same alert several times per attempt.
##  - the host's OWN device never notifies itself.

const DEBOUNCE_S := 8.0
const SOUND_COOLDOWN_S := 4.0

static var _last_notice_ms := -1  # -1 = never notified
static var _last_sound_ms := -1
static var _notifier_ok: int = -1  # -1 unknown, 0 unavailable, 1 available


## Fire a "player wants in" alert on the host machine. When `url` is given,
## the notification carries an "Open dashboard" action that opens it.
static func notify_join(player_name: String, code: String, count: int,
		max_players: int, url: String = "") -> Dictionary:
	var now := Time.get_ticks_msec()
	# -1 means "never", so the first join always notifies instead of looking
	# like it fired at process start.
	var throttled := _last_notice_ms >= 0 and \
		(now - _last_notice_ms) < int(DEBOUNCE_S * 1000)
	_last_notice_ms = now
	_beep(now)
	if throttled:
		return {"sent": false, "reason": "debounced"}
	var body := "%s wants to join room %s  (%d/%d)" % [
		player_name, code, count, max_players]
	var sent := _desktop(body, url)
	return {"sent": sent, "body": body, "player": player_name, "code": code,
		"url": url}


static func _beep(now: int) -> void:
	if _last_sound_ms >= 0 and (now - _last_sound_ms) < int(SOUND_COOLDOWN_S * 1000):
		return
	_last_sound_ms = now
	# Terminal bell: works on any Linux desktop without extra assets, and is
	# harmless when nothing is attached to the TTY.
	OS.execute("bash", PackedStringArray(["-c", "printf '\\a' > /dev/tty 2>/dev/null; true"]))


static func _desktop(body: String, url: String = "") -> bool:
	if _notifier_ok == 0:
		return false
	var exe := "notify-send"
	if OS.get_name() == "Windows":
		# PowerShell toast-free fallback: a tray balloon via balloon tip.
		return _windows_balloon(body)
	if OS.get_name() == "macOS":
		exe = "osascript"
		var script := "display notification \"%s\" with title \"Cloud Arena\"" % \
			body.replace("\"", "'")
		OS.create_process("/usr/bin/osascript",
			PackedStringArray(["-e", script]))
		return true
	# Linux: prefer a clickable "Open dashboard" action when a URL is known.
	# Runs detached (notify-send blocks while the notification is up), and
	# falls back to a plain notification if --action is unsupported.
	if url != "":
		var pid := OS.create_process("/bin/sh",
			PackedStringArray(["-c", _clickable_script(body, url)]))
		if pid > 0:
			_notifier_ok = 1
			return true
	var args := PackedStringArray(["-a", "Cloud Arena", "-u", "critical",
		"--", body])
	var pid2 := OS.create_process(exe, args)
	if pid2 <= 0 and _notifier_ok == -1:
		# try the absolute path before giving up
		pid2 = OS.create_process("/usr/bin/notify-send", args)
	if pid2 <= 0:
		_notifier_ok = 0
		return false
	_notifier_ok = 1
	return true


## Detached shell wrapper: show the notification with an action button, and
## open the dashboard deep link when it is clicked. `--wait` implies the call
## blocks until dismissal, so everything runs in its own process.
## notify-send takes actions as NAME=Label (equals, not comma) and echoes the
## NAME back on stdout when the button is clicked.
static func _clickable_script(body: String, url: String) -> String:
	var b := _sh_quote(body)
	var u := _sh_quote(url)
	return ("if k=$(notify-send -a 'Cloud Arena' -u critical --wait"
		+ " --expire-time=0 --action='open=Open dashboard' -- " + b
		+ " 2>/dev/null); then"
		+ " [ \"$k\" = open ] && xdg-open " + u + " >/dev/null 2>&1 &"
		+ " else notify-send -a 'Cloud Arena' -u critical -- " + b
		+ " >/dev/null 2>&1 & fi")


## POSIX single-quote escaping for embedding a string in a shell command.
static func _sh_quote(s: String) -> String:
	return "'" + s.replace("'", "'\\''") + "'"


static func _windows_balloon(body: String) -> bool:
	var script := ("Add-Type -AssemblyName System.Windows.Forms;"
		+ "$n=New-Object System.Windows.Forms.NotifyIcon;"
		+ "$n.Icon=[System.Drawing.SystemIcons]::Information;"
		+ "$n.BalloonTipTitle='Cloud Arena';$n.BalloonTipText='%s';"
		+ "$n.Visible=$true;$n.ShowBalloonTip(5000)") % body.replace("'", "''")
	OS.create_process("powershell", PackedStringArray([
		"-NoProfile", "-Command", script]))
	return true
