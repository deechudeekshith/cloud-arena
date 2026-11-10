class_name MonitorLink
extends Node

## Lightweight local telemetry + command channel to the monitoring service.
## Additive only: gameplay/netcode never depend on it. Uses plain HTTP on
## localhost (separate from game traffic; own byte counters so monitoring
## overhead is measured independently and never mixed into game bandwidth).
## All failures are silent + retried: the game runs fine with no service.
##
## CLOUD MULTIPLAYER: Uses ServerConfig for automatic endpoint configuration.
## In development mode, connects to localhost:8901. In production mode,
## connects to cloud VPS monitor API (HTTPS).

signal command_result(cmd_id: String, ok: bool, detail: String)

var game: Node = null # GameRoot
var server_config: ServerConfig = null  # Set by GameRoot
var base_url := "http://127.0.0.1:8901"
# Stable device identity (set by GameRoot): lets the monitor group telemetry
# per physical device instead of a single anonymous game stream.
var device_id := ""
var enabled := true
var post_interval := 1.0
var poll_interval := 2.0
var port := 8901 # monitor service port; paired with the resolved host
var bytes_out := 0
var bytes_in := 0
var last_ok_msec := 0
var _post_acc := 0.0
var _poll_acc := 0.0
var _sent_samples := 0 # metrics.samples already forwarded
var _backoff := 1.0
var _req_post: HTTPRequest
var _req_poll: HTTPRequest
var _req_ack: HTTPRequest
# fire-and-forget POSTs that must not collide with the telemetry stream
# (held-join registration/resolution): one at a time, FIFO
var _req_aux: HTTPRequest
var _aux_q: Array = []
var _aux_busy := false
var _acking := false
var _ack_pending := ""
var _ack_coalesced := 0
var _posting := false
var _polling := false

## Work out where the monitor service actually lives.
##
## CLOUD MULTIPLAYER: Priority order:
##   1. ServerConfig (production cloud endpoint or development localhost)
##   2. explicit override (CLI/config) always wins
##   3. CLOUD_ARENA_MONITOR environment variable
##   4. the room host we actually connected to (the monitor runs on the same
##      PC as the host, one port over from the game)
##   5. loopback, for single-machine desktop runs
func resolve_base_url(override: String = "", game_host: String = "") -> String:
	# Priority 1: Use ServerConfig if available
	if server_config != null:
		base_url = server_config.get_monitor_url()
		print("[MonitorLink] Using ServerConfig endpoint: %s" % base_url)
		return base_url
	
	# Priority 2: Explicit override
	var o := override.strip_edges()
	if o != "":
		base_url = o
		return base_url
	
	# Priority 3: Environment variable
	var env := OS.get_environment("CLOUD_ARENA_MONITOR").strip_edges()
	if env != "":
		base_url = env
		return base_url
	
	# Priority 4: Game host (LAN/cloud server)
	var h := host_only(game_host)
	if h != "" and h != "127.0.0.1" and h != "localhost" and h != "0.0.0.0":
		base_url = "http://%s:%d" % [h, port]
		return base_url
	
	# Priority 5: Localhost fallback
	base_url = "http://127.0.0.1:%d" % port
	return base_url

## Strip scheme and port from a ws://host:port or bare host string.
func host_only(addr: String) -> String:
	var s := addr.strip_edges()
	if s == "":
		return ""
	for p in ["ws://", "wss://", "http://", "https://"]:
		if s.begins_with(p):
			s = s.substr(p.length())
			break
	if s.contains("/"):
		s = s.get_slice("/", 0)
	if s.contains(":"):
		s = s.get_slice(":", 0)
	return s

# A final push (e.g. match end) can arrive while a POST is in flight; HTTP
# allows one request at a time, so the payload is retried once free instead
# of being dropped.
var _post_again := false
# events/samples carried by the in-flight payload (ack clears only those)
var _inflight_events := 0
var _inflight_samples := 0

func _ready() -> void:
	_req_post = HTTPRequest.new()
	_req_post.timeout = 5.0
	add_child(_req_post)
	_req_post.request_completed.connect(_on_post_done)
	_req_poll = HTTPRequest.new()
	_req_poll.timeout = 5.0
	add_child(_req_poll)
	_req_poll.request_completed.connect(_on_poll_done)
	# ACKs get their OWN request node. Sharing _req_post made every command ACK
	# collide with the 1 Hz telemetry post on the same HTTPRequest, which Godot
	# rejects outright ("HTTPRequest is processing a request"), so command
	# results were silently lost -- very visible on the Web build where posts
	# are slow and overlap constantly.
	_req_ack = HTTPRequest.new()
	_req_ack.timeout = 5.0
	add_child(_req_ack)
	_req_ack.request_completed.connect(_on_ack_done)
	_req_aux = HTTPRequest.new()
	_req_aux.timeout = 5.0
	add_child(_req_aux)
	_req_aux.request_completed.connect(_on_aux_done)

## Queue a one-shot JSON POST (held-join bookkeeping). Never blocks or fails
## the caller: dropped only if the service is unreachable.
func post_aux(path: String, body: Dictionary) -> void:
	if not enabled:
		return
	_aux_q.append({"path": path, "body": JSON.stringify(body)})
	_aux_pump()

func _aux_pump() -> void:
	if _aux_busy or _aux_q.is_empty():
		return
	var item: Dictionary = _aux_q.pop_front()
	var body := str(item["body"])
	bytes_out += body.length()
	_aux_busy = true
	var err := _req_aux.request(_url(str(item["path"])),
		["Content-Type: application/json"], HTTPClient.METHOD_POST, body)
	if err != OK:
		_aux_busy = false

func _on_aux_done(_res: int, _code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
	_aux_busy = false
	bytes_in += body.size()
	_aux_pump()

func _process(dt: float) -> void:
	if not enabled or game == null:
		return
	_post_acc += dt
	_poll_acc += dt
	if (_post_acc >= post_interval or _post_again) and not _posting:
		_post_acc = 0.0
		_post_again = false
		_post_telemetry()
	if _poll_acc >= poll_interval and not _polling:
		_poll_acc = 0.0
		_poll_commands()

## Request an immediate push of any pending samples/events. Returns false
## if the data could not be handed to the transport yet (it will retry).
func flush() -> bool:
	if _posting:
		_post_again = true
		return false
	_post_telemetry()
	return not _posting

## True while telemetry still needs to reach the service.
func has_pending() -> bool:
	return _posting or _post_again

func _url(path: String) -> String:
	return base_url.rstrip("/") + path

func _post_telemetry() -> void:
	if game == null or not game.has_method("collect_telemetry"):
		return
	var tel: Dictionary = game.collect_telemetry()
	# identify the sender by role AND device: a host and several guests run in
	# the same monitor and must not overwrite each other's live slot
	var client := "godot:" + str(tel.get("src", "solo")) + ":" + \
		(device_id if device_id != "" else str(tel.get("device_id", "nodev")))
	var body := JSON.stringify({"client": client, "device_id": device_id,
		"room_code": str(tel.get("room_code", "")), "telemetry": tel})
	bytes_out += body.length()
	# remember how many events this payload carried: events appended while
	# the request is in flight must NOT be cleared by its acknowledgement
	_inflight_events = (tel.get("events", []) as Array).size()
	_inflight_samples = (tel.get("new_samples", []) as Array).size()
	_posting = true
	var err := _req_post.request(_url("/api/ingest"), ["Content-Type: application/json"],
		HTTPClient.METHOD_POST, body)
	if err != OK:
		_posting = false

func _on_post_done(_res: int, code: int, _hdrs: PackedStringArray, body: PackedByteArray) -> void:
	_posting = false
	bytes_in += body.size()
	if code >= 200 and code < 300:
		last_ok_msec = Time.get_ticks_msec()
		_backoff = 1.0
		if game and game.has_method("confirm_telemetry_sent"):
			game.confirm_telemetry_sent(_inflight_samples, _inflight_events)
		if _post_again:
			_post_again = false
			_post_telemetry()
	else:
		_post_again = true # retry next frame (service may be restarting)

func _poll_commands() -> void:
	_polling = true
	var err := _req_poll.request(_url("/api/commands?client=godot"))
	if err != OK:
		_polling = false

func _on_poll_done(_res: int, code: int, _hdrs: PackedStringArray, body: PackedByteArray) -> void:
	_polling = false
	if code < 200 or code >= 300:
		return
	bytes_in += body.size()
	var v = JSON.parse_string(body.get_string_from_utf8())
	if not (v is Dictionary):
		return
	for c in v.get("commands", []):
		_apply_command(c)

func _apply_command(c: Dictionary) -> void:
	var cid := str(c.get("id", ""))
	var cmd := str(c.get("cmd", ""))
	var params: Dictionary = c.get("params", {})
	var ok := false
	var detail := ""
	if game and game.has_method("apply_monitor_command"):
		var r: Dictionary = game.apply_monitor_command(cmd, params)
		# "owned: false" = this game instance is not the target (e.g. a client
		# seeing a host-only command, or a second host for a different room).
		# Leave it QUEUED for the right instance instead of poisoning the row
		# with a FAILED ack.
		if not bool(r.get("owned", true)):
			return
		ok = bool(r.get("applied", false))
		detail = str(r.get("detail", r.get("error", "")))
	else:
		detail = "game has no command handler"
	_ack(cid, ok, detail)
	command_result.emit(cid, ok, detail)

func _ack(cid: String, ok: bool, detail: String) -> void:
	var body := JSON.stringify({"id": cid,
		"status": "APPLIED" if ok else "FAILED", "detail": detail})
	bytes_out += body.length()
	# Never drop an ACK: if one is still in flight, queue the newest and send
	# it as soon as the current request finishes.
	if _acking:
		_ack_pending = body
		_ack_coalesced += 1
		return
	_acking = true
	_req_ack.request(_url("/api/ack"), ["Content-Type: application/json"],
		HTTPClient.METHOD_POST, body)

func _on_ack_done(_res: int, _code: int, _h: PackedStringArray, _b: PackedByteArray) -> void:
	if _ack_pending == "":
		_acking = false
		return
	var nxt := _ack_pending
	_ack_pending = ""
	_req_ack.request(_url("/api/ack"), ["Content-Type: application/json"],
		HTTPClient.METHOD_POST, nxt)
