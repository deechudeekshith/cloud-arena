# REAL 2-process multiplayer verification (loopback ENet, no fakes).
# Host: creates room, waits for guest, starts net match, simulates 25s.
# Guest: joins via 127.0.0.1, plays (moves+fires), verifies snapshots.
# Run: godot --headless --path <proj> --script res://tests/NetLink.gd -- --role host --port 7779 --dir /tmp/opencode/nettest
#      godot --headless --path <proj> --script res://tests/NetLink.gd -- --role client --port 7779 --dir /tmp/opencode/nettest
extends SceneTree

var frames := 0
var main: Node = null
var role := "host"
var port := 7779
var dir := "/tmp/opencode/nettest"
var t0 := 0
var started := false
var guest_fires := 0
var snaps := 0
var snap_players_max := 0

func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			role = a.get_slice("=", 1)
		elif a.begins_with("--port="):
			port = int(a.get_slice("=", 1))
		elif a.begins_with("--dir="):
			dir = a.get_slice("=", 1)
	DirAccess.make_dir_recursive_absolute(dir)
	var ps: PackedScene = load("res://scenes/main/Main.tscn")
	main = ps.instantiate()
	root.add_child(main)
	t0 = Time.get_ticks_msec()

func _elapsed() -> float:
	return float(Time.get_ticks_msec() - t0) / 1000.0

func _write(name: String, text: String) -> void:
	var f := FileAccess.open(dir + "/" + name, FileAccess.WRITE)
	if f:
		f.store_string(text)

func _process(_dt: float) -> bool:
	frames += 1
	if role == "host":
		return _host()
	return _client()

func _host() -> bool:
	if frames == 5:
		main.settings.approve_joins = false # host self-approves; no dashboard
		main._on_create_room()
		_write("code.txt", main.my_room_code)
		print("NETLINK host: room ", main.my_room_code)
	if frames > 5 and not started:
		var room: Dictionary = main.room_mgr.get_room(main.my_room_code)
		var humans := 0
		if not room.is_empty():
			for pl in room["players"]:
				if not bool((pl as Dictionary).get("is_bot", false)):
					humans += 1
		if humans >= 2 and _elapsed() > 4.0:
			started = true
			main._on_room_start()
			print("NETLINK host: match started, mode=", main.net_mode)
	if started and _elapsed() > 45.0:
		var t = main.net
		var gfires := 0
		for cid in main.last_fire_msec:
			if int(cid) != 0 and int(main.last_fire_msec[cid]) > 0:
				gfires += 1
		print("NETLINK host: combatants=", main.combatants.size(),
			" scores=", main.team_scores, " sent=", t.bytes_sent,
			" recv=", t.bytes_received, " pkts=", t.packets_sent + t.packets_received,
			" guest_fired=", gfires > 0)
		_write("host_done.txt", "scores=%s sent=%d recv=%d guest_fired=%s" % [
			str(main.team_scores), t.bytes_sent, t.bytes_received, str(gfires > 0)])
		return true
	if _elapsed() > 60.0:
		print("NETLINK host: TIMEOUT phase=", main.phase, " net=", main.net_mode)
		_write("host_done.txt", "TIMEOUT")
		return true
	return false

func _client() -> bool:
	if frames == 5:
		var code := ""
		for i in 200:
			if FileAccess.file_exists(dir + "/code.txt"):
				code = FileAccess.get_file_as_string(dir + "/code.txt").strip_edges()
				break
			OS.delay_msec(100)
		print("NETLINK client: joining code ", code)
		main._start_net_join("127.0.0.1", port, code)
	if main.net_mode == "client" and main.phase == 2:
		if not started:
			started = true
			main.net.snapshot_received.connect(func(s: Dictionary, _b: int) -> void:
				snaps += 1
				if s.has("players"):
					snap_players_max = maxi(snap_players_max, (s["players"] as Array).size()))
		# play: hold forward, burst fire
		Input.action_press("move_forward")
		if int(_elapsed()) % 4 < 2:
			Input.action_press("fire")
		else:
			Input.action_release("fire")
	if main.net != null and main.net_mode == "client":
		pass
	if started and _elapsed() > 25.0:
		if main.net == null or main.player == null:
			_write("client_done.txt", "NO_NET")
			return true
		var t = main.net
		var pups: int = main.puppets.size()
		print("NETLINK client: puppets=", pups, " myhp=", main.player.health.hp,
			" myid=", main.my_net_id, " snaps=", snaps, " snap_players_max=", snap_players_max,
			" mode=", main.comm.mode if main.comm else "null",
			" sent=", t.bytes_sent, " recv=", t.bytes_received,
			" loss=", t.loss_of("snap"), " rtt=", t.rtt_of(1))
		_write("client_done.txt", "puppets=%d hp=%d sent=%d recv=%d loss=%f rtt=%f" % [
			pups, int(main.player.health.hp), t.bytes_sent, t.bytes_received,
			t.loss_of("snap"), t.rtt_of(1)])
		return true
	if _elapsed() > 60.0:
		print("NETLINK client: TIMEOUT phase=", main.phase, " net=", main.net_mode,
			" puppets=", main.puppets.size())
		_write("client_done.txt", "TIMEOUT")
		return true
	return false
