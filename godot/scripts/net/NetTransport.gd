class_name NetTransport
extends Node

## Real ENet transport (host authoritative). Byte/packet accounting counts
## our serialized payloads (var_to_bytes at send); ENet framing overhead is
## NOT included and this is documented, never presented as wire bytes.
## Channels: unreliable = input/snapshot/ping (20Hz+); reliable = hello,
## welcome, fire, pickup, lobby, events. Loss is MEASURED from sequence
## gaps on the unreliable streams. RTT is MEASURED with ping/pong echo.

signal peer_joined(peer_id: int)
signal peer_left(peer_id: int)
signal hello_received(peer_id: int, hello: Dictionary)
signal input_received(peer_id: int, inp: Dictionary)
signal fire_received(peer_id: int, fire: Dictionary)
signal pickup_received(peer_id: int,req: Dictionary)
signal ready_received(peer_id: int)
signal snapshot_received(snap: Dictionary, wire_bytes: int)
signal event_received(ev: Dictionary)
signal lobby_received(room: Dictionary)
signal welcome_received(info: Dictionary)
signal starting_received(info: Dictionary)
signal shot_received(shot: Dictionary)
signal rtt_updated(peer_id: int, rtt_ms: float)

const PROTO := 1

## Transport selection. WEBSOCKET works from BOTH native (PC/Android) and
## the web export, so a PC-hosted room can accept browser + phone clients.
## ENET is kept for legacy LAN-only desktop play. All RPC/serialization
## above this layer is transport-agnostic.
enum Transport { ENET, WEBSOCKET }
var transport: int = Transport.WEBSOCKET

var peer: MultiplayerPeer
var is_host := false
# Last address passed to join(); empty while hosting. Used to locate the
# monitor service running on the same PC as the room host.
var remote_addr := ""
var connected := false
## Loopback/test tap + injection. When tap_out is set, every outbound
## payload is ALSO delivered to it as tap_out(kind, payload_bytes_or_dict).
## inject_* feeds inbound data through the normal validated receive path.
## Used by automated tests and (Phase 13) simulated-link conditions.
## Real socket delivery is untouched and always runs.
var tap_out: Callable

var bytes_sent := 0
var bytes_received := 0
var packets_sent := 0
var packets_received := 0
var decomp_us_total := 0
# loss tracking: stream key -> {expected, received, lost}
var _streams := {}
# rtt: peer_id -> {last_ping, rtt}
var _rtt := {}
var _ping_t := 0.0

func _exit_tree() -> void:
	close()

func close() -> void:
	connected = false
	is_host = false
	if peer:
		peer.close()
		peer = null
	if multiplayer.multiplayer_peer is MultiplayerPeer:
		multiplayer.multiplayer_peer = null

func host(port: int) -> bool:
	close()
	if transport == Transport.WEBSOCKET:
		var ws := WebSocketMultiplayerPeer.new()
		if ws.create_server(port) != OK:
			return false
		peer = ws
	else:
		var enet := ENetMultiplayerPeer.new()
		if enet.create_server(port, RoomManager.MAX_PLAYERS) != OK:
			return false
		peer = enet
	is_host = true
	connected = true
	multiplayer.multiplayer_peer = peer
	peer.peer_connected.connect(_on_peer_connected)
	peer.peer_disconnected.connect(_on_peer_disconnected)
	return true

func join(ip: String, port: int) -> bool:
	close()
	# Remembered so other subsystems (notably MonitorLink) can reach services
	# on the same machine we are joining, e.g. a phone reporting telemetry to
	# the PC that is hosting the room.
	remote_addr = ip
	if transport == Transport.WEBSOCKET:
		var url := ip
		if not (url.begins_with("ws://") or url.begins_with("wss://")):
			url = "ws://%s:%d" % [ip, port]
		var ws := WebSocketMultiplayerPeer.new()
		if ws.create_client(url) != OK:
			return false
		peer = ws
	else:
		var enet := ENetMultiplayerPeer.new()
		if enet.create_client(ip, port) != OK:
			return false
		peer = enet
	is_host = false
	multiplayer.multiplayer_peer = peer
	peer.peer_connected.connect(_on_server_connected)
	peer.peer_disconnected.connect(_on_server_gone)
	return true

func _on_peer_connected(id: int) -> void:
	peer_joined.emit(id)

func _on_peer_disconnected(id: int) -> void:
	peer_left.emit(id)

func _on_server_connected(_id: int) -> void:
	connected = true

func _on_server_gone(_id: int) -> void:
	connected = false
	peer_left.emit(1)

# ---------------- accounting ----------------
func _out(d: Dictionary) -> void:
	bytes_sent += var_to_bytes(d).size()
	packets_sent += 1

func _in(d: Dictionary) -> void:
	bytes_received += var_to_bytes(d).size()
	packets_received += 1

func _note_seq(stream: String, seq: int) -> void:
	var st: Dictionary = _streams.get(stream, {"expected": -1, "received": 0, "lost": 0})
	if int(st["expected"]) < 0:
		st["expected"] = seq
	if seq > int(st["expected"]):
		st["lost"] = int(st["lost"]) + (seq - int(st["expected"]))
		st["expected"] = seq + 1
	elif seq == int(st["expected"]):
		st["expected"] = seq + 1
	st["received"] = int(st["received"]) + 1
	_streams[stream] = st

## Measured loss fraction 0..1 for a stream, -1 if no data yet.
func loss_of(stream: String) -> float:
	var st: Dictionary = _streams.get(stream, {})
	var total: int = int(st.get("received", 0)) + int(st.get("lost", 0))
	if total <= 0:
		return -1.0
	return float(st.get("lost", 0)) / float(total)

func rtt_of(peer_id: int) -> float:
	return float((_rtt.get(peer_id, {}) as Dictionary).get("rtt", -1.0))

# ---------------- validation ----------------
static func _finite(v: Variant) -> bool:
	if v is float:
		return not (is_nan(v) or is_inf(v))
	if v is Vector2 or v is Vector3:
		for c in [v.x, v.y] + ([v.z] if v is Vector3 else []):
			if is_nan(c) or is_inf(c):
				return false
		return true
	return true

static func valid_input(d: Dictionary) -> bool:
	if int(d.get("proto", 0)) != PROTO:
		return false
	var mv: Array = d.get("move", [])
	if mv.size() != 2 or not _finite(mv[0]) or not _finite(mv[1]):
		return false
	if Vector2(float(mv[0]), float(mv[1])).length() > 1.25:
		return false
	return true

func _live() -> bool:
	return multiplayer.multiplayer_peer != null

## Targeted send guards. Broadcast (rpc) is safe with zero peers; direct
## rpc_id needs a live link or Godot logs "on yourself" errors.
func _to_server() -> bool:
	return _live() and not is_host and multiplayer.get_unique_id() > 1

func _to_peer(peer_id: int) -> bool:
	return _live() and is_host and multiplayer.get_peers().has(peer_id)

# ---------------- send API ----------------
func send_input(inp: Dictionary) -> void:
	_out(inp)
	if _to_server():
		rpc_id(1, "_net_input", inp)
	if tap_out.is_valid():
		tap_out.call("input", inp)

func send_fire(fire: Dictionary) -> void:
	_out(fire)
	if _to_server():
		rpc_id(1, "_net_fire", fire)
	if tap_out.is_valid():
		tap_out.call("fire", fire)

func send_pickup(req: Dictionary) -> void:
	_out(req)
	if _to_server():
		rpc_id(1, "_net_pickup", req)
	if tap_out.is_valid():
		tap_out.call("pickup", req)

func send_ready() -> void:
	var d := {"proto": PROTO}
	_out(d)
	if _to_server():
		rpc_id(1, "_net_ready", d)

func send_hello(hello: Dictionary) -> void:
	_out(hello)
	if _to_server():
		rpc_id(1, "_net_hello", hello)

func send_welcome(peer_id: int, info: Dictionary) -> void:
	_out(info)
	if _to_peer(peer_id):
		rpc_id(peer_id, "_net_welcome", info)

func send_snapshot(snap: Dictionary) -> void:
	_out(snap)
	if _live():
		rpc("_net_snapshot", snap)

## Encoded broadcast (goes through the CommManager pipeline).
## Returns the encode result dict for metrics.
func broadcast_snapshot(enc: Dictionary) -> void:
	var payload: PackedByteArray = enc.get("bytes", PackedByteArray())
	bytes_sent += payload.size()
	packets_sent += 1
	if _live():
		rpc("_net_snapshot_raw", payload)
	if tap_out.is_valid():
		tap_out.call("snapshot", payload)

func inject_snapshot(snap: Dictionary, wire_bytes: int) -> void:
	_note_seq("snap", int(snap.get("seq", 0)))
	snapshot_received.emit(snap, wire_bytes)

func inject_event(ev: Dictionary) -> void:
	event_received.emit(ev)

func inject_shot(shot: Dictionary) -> void:
	shot_received.emit(shot)

func send_event(ev: Dictionary) -> void:
	_out(ev)
	if _live():
		rpc("_net_event", ev)
	if tap_out.is_valid():
		tap_out.call("event", ev)

func send_lobby(room: Dictionary) -> void:
	_out(room)
	if _live():
		rpc("_net_lobby", room)

func send_starting(peer_id: int, info: Dictionary) -> void:
	_out(info)
	if _to_peer(peer_id):
		rpc_id(peer_id, "_net_starting", info)

## Cosmetic shot echo (tracer endpoints for remote rendering).
## Damage is NEVER carried here; the host sim is authoritative.
func send_shot(shot: Dictionary) -> void:
	_out(shot)
	if _live():
		rpc("_net_shot", shot)
	if tap_out.is_valid():
		tap_out.call("shot", shot)

func send_ping(peer_id: int) -> void:
	var d := {"proto": PROTO, "t": Time.get_ticks_msec(), "echo": false}
	_out(d)
	if is_host:
		if _to_peer(peer_id):
			rpc_id(peer_id, "_net_ping", d)
	else:
		if _to_server():
			rpc_id(1, "_net_ping", d)

func _process(dt: float) -> void:
	if peer == null:
		return
	# WebSocketMultiplayerPeer does not emit peer_connected on the CLIENT
	# side (unlike ENet), so derive the connected flag from the peer status.
	if not connected and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		connected = true
		if not is_host:
			_on_server_connected(multiplayer.get_unique_id())
	if not connected:
		return
	_ping_t += dt
	if _ping_t >= 1.0:
		_ping_t = 0.0
		if is_host:
			for id in multiplayer.get_peers():
				send_ping(id)
		else:
			send_ping(1)

# ---------------- receive RPCs ----------------
@rpc("any_peer", "unreliable")
func _net_input(d: Dictionary) -> void:
	_in(d)
	if not is_host or not valid_input(d):
		return
	_note_seq("in:%d" % multiplayer.get_remote_sender_id(), int(d.get("seq", 0)))
	input_received.emit(multiplayer.get_remote_sender_id(), d)

@rpc("any_peer", "reliable")
func _net_fire(d: Dictionary) -> void:
	_in(d)
	if is_host and int(d.get("proto", 0)) == PROTO:
		fire_received.emit(multiplayer.get_remote_sender_id(), d)

@rpc("any_peer", "reliable")
func _net_pickup(d: Dictionary) -> void:
	_in(d)
	if is_host and int(d.get("proto", 0)) == PROTO:
		pickup_received.emit(multiplayer.get_remote_sender_id(), d)

@rpc("any_peer", "reliable")
func _net_ready(d: Dictionary) -> void:
	_in(d)
	if is_host:
		ready_received.emit(multiplayer.get_remote_sender_id())

@rpc("any_peer", "reliable")
func _net_hello(d: Dictionary) -> void:
	_in(d)
	if is_host and int(d.get("proto", 0)) == PROTO:
		hello_received.emit(multiplayer.get_remote_sender_id(), d)

@rpc("any_peer", "reliable")
func _net_welcome(d: Dictionary) -> void:
	_in(d)
	if not is_host:
		welcome_received.emit(d)

@rpc("any_peer", "unreliable")
func _net_snapshot(d: Dictionary) -> void:
	_in(d)
	if not is_host and int(d.get("proto", 0)) == PROTO:
		_note_seq("snap", int(d.get("seq", 0)))
		snapshot_received.emit(d, var_to_bytes(d).size())

var comm: CommManager # set by GameRoot; decodes pipeline payloads

@rpc("any_peer", "unreliable")
func _net_snapshot_raw(payload: PackedByteArray) -> void:
	bytes_received += payload.size()
	packets_received += 1
	if is_host or comm == null:
		return
	var res: Dictionary = comm.decode_snapshot(payload)
	if not bool(res.get("ok", false)):
		return
	decomp_us_total += int(res.get("decomp_us", 0))
	if bool(res.get("repeat", false)):
		var rsnap := {"repeat": true, "scores": res.get("scores", []),
			"time_left": res.get("time_left", 0.0), "seq": res.get("seq", 0)}
		_note_seq("snap", int(rsnap.get("seq", 0)))
		snapshot_received.emit(rsnap, payload.size())
		return
	var snap: Dictionary = res["snap"]
	_note_seq("snap", int(snap.get("seq", 0)))
	snapshot_received.emit(snap, payload.size())

@rpc("any_peer", "reliable")
func _net_event(d: Dictionary) -> void:
	_in(d)
	if not is_host and int(d.get("proto", 0)) == PROTO:
		event_received.emit(d)

@rpc("any_peer", "reliable")
func _net_lobby(d: Dictionary) -> void:
	_in(d)
	if not is_host:
		lobby_received.emit(d)

@rpc("any_peer", "reliable")
func _net_starting(d: Dictionary) -> void:
	_in(d)
	if not is_host:
		starting_received.emit(d)

@rpc("any_peer", "unreliable")
func _net_shot(d: Dictionary) -> void:
	_in(d)
	if int(d.get("proto", 0)) == PROTO:
		shot_received.emit(d)

@rpc("any_peer", "unreliable")
func _net_ping(d: Dictionary) -> void:
	_in(d)
	var sender := multiplayer.get_remote_sender_id()
	if bool(d.get("echo", false)):
		var st: Dictionary = _rtt.get(sender if sender != 0 else 1, {"rtt": -1.0})
		st["rtt"] = float(Time.get_ticks_msec() - int(d.get("t", 0)))
		_rtt[sender if sender != 0 else 1] = st
		rtt_updated.emit(sender, float(st["rtt"]))
	else:
		var back := {"proto": PROTO, "t": int(d.get("t", 0)), "echo": true}
		_out(back)
		if is_host:
			if _live():
				rpc_id(sender, "_net_ping", back)
		else:
			if _to_server():
				rpc_id(1, "_net_ping", back)
