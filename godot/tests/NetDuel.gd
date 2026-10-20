# Full replication verification WITHOUT sockets (this container drops
# loopback UDP; see report). Two live GameRoots in one process — host sim
# + client world — exchanging REAL encoded snapshots/events through the
# production CommManager/submit paths; only socket delivery is replaced
# by direct tap shuttling. tests/NetLink.gd covers real sockets on LAN.
# Run: godot --headless --path <project> --script res://tests/NetDuel.gd
extends SceneTree

var frames := 0
var host: Node = null
var guest: Node = null
var results: Array = []
var t0 := 0
var snaps_to_guest := 0
var started := false
var gstart := Vector3.ZERO
var run_mode := "NORMAL"
var sim: NetSim
var sim_desc := "off"

func _initialize() -> void:
	t0 = Time.get_ticks_msec()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--mode="):
			run_mode = a.get_slice("=", 1).to_upper()
		elif a.begins_with("--sim="):
			var parts := a.get_slice("=", 1).split(",")
			sim = NetSim.new()
			sim.configure(float(parts[0]), float(parts[1]) if parts.size() > 1 else 0.0,
				float(parts[2]) if parts.size() > 2 else 0.0)
			sim_desc = sim.describe()
	var ps: PackedScene = load("res://scenes/main/Main.tscn")
	host = ps.instantiate()
	root.add_child(host)
	guest = ps.instantiate()
	root.add_child(guest)

func _el() -> float:
	return float(Time.get_ticks_msec() - t0) / 1000.0

func _process(_dt: float) -> bool:
	frames += 1
	if frames == 5:
		_setup()
	if sim:
		sim.update()
	if started and guest.phase == 2:
		# drive the GUEST (host idles; shared Input moves both, harmless)
		Input.action_press("move_forward")
		if int(_el()) % 4 < 2:
			Input.action_press("fire")
		else:
			Input.action_release("fire")
	if started and _el() > 45.0:
		_finish()
		return true
	if _el() > 120.0:
		print("NETDUEL: TIMEOUT")
		_finish()
		return true
	return false

func _setup() -> void:
	host._on_create_room()
	var code: String = host.my_room_code
	var res: Dictionary = host.room_mgr.join_room(code, "Guest", 1)
	var entry: Dictionary = res["player"]
	entry["cid"] = host._free_cid(host.room_mgr.get_room(code))
	host.peer_pid[2] = entry["pid"]
	host.room_mgr.set_ready(code, entry["pid"], true)
	host.room_mgr.set_mode(code, run_mode)
	host.room_mgr.lock_room(code)
	host.room_mgr.set_state(code, "PLAYING")
	host.start_net_host()
	host.net.tap_out = Callable(self, "_ab")
	guest._ensure_net()
	guest.start_net_client({"cid": int(entry["cid"]), "team": int(entry["team"]),
		"seed": int(host.room_mgr.get_room(code)["map_seed"]), "mode": run_mode})
	guest.net.tap_out = Callable(self, "_ba")
	gstart = (host._by_id(1) as Node3D).global_position
	started = true
	print("NETDUEL: host+guest worlds up, guest cid=", entry["cid"])

# host -> guest wire (optionally through the NetSim conditioner)
func _ab(kind: String, payload: Variant) -> void:
	if guest == null:
		return
	if sim:
		var sz := (payload as PackedByteArray).size() if kind == "snapshot" else var_to_bytes(payload).size()
		sim.send(kind, payload, sz, Callable(self, "_ab_deliver"))
	else:
		_ab_deliver(kind, payload)

func _ab_deliver(kind: String, payload: Variant) -> void:
	if guest == null:
		return
	match kind:
		"snapshot":
			var dec: Dictionary = guest.comm.decode_snapshot(payload)
			if bool(dec.get("ok", false)):
				snaps_to_guest += 1
				guest.net.inject_snapshot(dec["snap"], (payload as PackedByteArray).size())
		"event":
			var rt = bytes_to_var(var_to_bytes(payload))
			guest.net.inject_event(rt)
		"shot":
			var rt2 = bytes_to_var(var_to_bytes(payload))
			guest.net.inject_shot(rt2)

# guest -> host wire
func _ba(kind: String, payload: Variant) -> void:
	if host == null:
		return
	match kind:
		"input":
			host._on_net_input(2, payload)
		"fire":
			host._on_net_fire(2, payload)
		"pickup":
			host._on_net_pickup(2, payload)

func _check(name: String, ok: bool, detail: String) -> void:
	results.append(ok)
	print("NETDUEL: [%s] %s %s" % ["PASS" if ok else "FAIL", name, ("(" + detail + ")") if detail != "" else ""])

func _finish() -> void:
	var hn = host.net
	var gn = guest.net
	var guest_body = host._by_id(1)
	var moved := 0.0
	if guest_body:
		moved = (guest_body as Node3D).global_position.distance_to(gstart)
	_check("snapshots flow", snaps_to_guest > 200, "n=%d" % snaps_to_guest)
	_check("guest puppets == 7", guest.puppets.size() == 7, "n=%d" % guest.puppets.size())
	_check("guest body moved (net input)", moved > 3.0, "%0.1fm" % moved)
	_check("guest shots validated", host.last_fire_msec.get(1, 0) != 0, "")
	_check("host bytes out", hn.bytes_sent > 10000, "%d" % hn.bytes_sent)
	_check("guest bytes out", gn.bytes_sent > 1000, "%d" % gn.bytes_sent)
	_check("guest hp live", guest.player.health.hp > 0.0 or guest.player.dead, "hp=%d" % int(guest.player.health.hp))
	if sim:
		_check("sim dropped packets", sim.stats()["dropped"] > 0, str(sim.stats()))
		_check("sim loss measured", gn.loss_of("snap") > 0.0, str(gn.loss_of("snap")))
	else:
		_check("snapshot loss == 0", gn.loss_of("snap") == 0.0, str(gn.loss_of("snap")))
	var fails := 0
	for r in results:
		if not r:
			fails += 1
	print("NETDUEL: DONE %d/%d passed" % [results.size() - fails, results.size()])
