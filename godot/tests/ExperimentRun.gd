# Repeatable experiment runner: fixed-config host match (8 combatants,
# bots fill), chosen codec mode + flags + net controls, streams telemetry
# to the local monitor, prints EXPERIMENT_DONE json, quits.
# Run: godot --headless --path <project> --script res://tests/ExperimentRun.gd
#   -- --mode=OPTIMIZED --seed=1234 --dur=180 --exp=exp01 --mon=8901
#   --rate=20 --budget=0 --flags=delta,dedup,compression,priority,partial
extends SceneTree

var frames := 0
var main: Node = null
var cfg := {"mode": "OPTIMIZED", "seed": 1234, "dur": 180, "exp": "",
	"mon": 8901, "rate": 20.0, "budget": 0.0, "peer": 0, "role": "host",
	"code": "", "port": 7777, "mpsize": 0, "medpct": 100, "lowpct": 100,
	"roomfile": "", "lat": 0.0, "jit": 0.0, "loss": 0.0, "sim_bw": 0.0,
	"flags": "delta,dedup,compression,priority,partial"}
var finished := false
var flushing := false
var flush_frames := 0
var t_start := 0
var pending_start := false
var peer_wait_start := 0

func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--"):
			var kv := a.substr(2).split("=", true, 1)
			if kv.size() == 2 and cfg.has(kv[0]):
				cfg[kv[0]] = kv[1]
	cfg["seed"] = int(cfg["seed"])
	cfg["dur"] = int(cfg["dur"])
	cfg["mon"] = int(cfg["mon"])
	cfg["rate"] = float(cfg["rate"])
	cfg["budget"] = float(cfg["budget"])
	cfg["peer"] = int(cfg["peer"])
	cfg["port"] = int(cfg["port"])
	cfg["mpsize"] = int(cfg["mpsize"])
	cfg["medpct"] = int(cfg["medpct"])
	cfg["lowpct"] = int(cfg["lowpct"])
	cfg["lat"] = float(cfg["lat"])
	cfg["jit"] = float(cfg["jit"])
	cfg["loss"] = float(cfg["loss"])
	cfg["sim_bw"] = float(cfg["sim_bw"])
	seed(int(cfg["seed"]))
	var ps: PackedScene = load("res://scenes/main/Main.tscn")
	main = ps.instantiate()
	root.add_child(main)
	t_start = Time.get_ticks_msec()

func _process(_dt: float) -> bool:
	frames += 1
	_maybe_start()
	if frames == 5:
		if str(cfg["role"]) == "guest":
			_setup_guest()
		else:
			_setup()
		return false
	if frames < 6:
		return false
	if main and main.phase == 2 and main.player and not bool(main.player.get("dead")):
		Input.action_press("move_forward")
		if frames % 90 < 45:
			Input.action_press("fire")
		else:
			Input.action_release("fire")
	if main and main.phase == 3 and not finished:
		finished = true
		_finish()
		flushing = true
		flush_frames = frames
		return false
	if flushing:
		# non-blocking final flush: let the main loop iterate so the
		# final POST (MATCH_ENDED + tail samples) completes before quit.
		if (not main.monitor.has_pending()) or frames - flush_frames > 420:
			return true
		return false
	if frames > 60 * (int(cfg["dur"]) + 60) and (Time.get_ticks_msec() - t_start) / 1000.0 > float(cfg["dur"]) + 180.0:
		print("EXPERIMENT: TIMEOUT phase=", main.phase if main else -1)
		_finish()
		return true
	return false

func _setup() -> void:
	main.settings.approve_joins = false # host self-approves; no dashboard here
	var room: Dictionary = main.room_mgr.create_room("Host", 0)
	main.my_room_code = str(room["code"])
	main.my_pid = str(room["host_pid"])
	main.am_host = true
	room["map_seed"] = int(cfg["seed"])
	main.room_mgr.set_mode(main.my_room_code, str(cfg["mode"]))
	main._ensure_net()
	main.net.host(int(cfg["port"]))
	# same room lifecycle event the interactive path emits, so the monitor's
	# room/session model works for headless runs too
	main._monitor_event("ROOM_CREATED", {
		"room_code": main.my_room_code,
		"room_id": str(room.get("room_id", "")),
		"max_players": int(room.get("max_players", 8)),
		"mode": str(room.get("mode", "NORMAL")),
		"host_device": main.device_id, "host_name": "Host"})
	_publish_room(main.my_room_code)
	if int(cfg["peer"]) > 0:
		# The guest must join while the room is LOBBY and the host must be
		# listening. Waiting must NOT block: the host's own socket polling
		# runs on the main loop, so the wait happens in _process instead.
		_spawn_peer(main.my_room_code)
		pending_start = true
		peer_wait_start = Time.get_ticks_msec()
	else:
		_start_match()
		return

## Hand the generated room code to the monitor service. The room code is
## created INSIDE this process, so the service cannot know it otherwise;
## writing it to the agreed path is the handoff the peer launcher waits on.
func _publish_room(code: String) -> void:
	if code == "":
		return
	var path := str(cfg["roomfile"])
	if path == "":
		path = ProjectSettings.globalize_path("res://").trim_suffix("/") \
			+ "/.room_" + str(cfg["exp"]) + ".txt"
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(code)
		f.close()
		print("EXPERIMENT: room code published ", code, " -> ", path)

## Deferred match start once the real peer is in the room (or on timeout).
func _maybe_start() -> void:
	if not pending_start or main == null:
		return
	var r: Dictionary = main.room_mgr.get_room(main.my_room_code)
	if not r.is_empty() and (r["players"] as Array).size() >= 2:
		print("EXPERIMENT: peer joined room, starting in ", (Time.get_ticks_msec() - peer_wait_start) / 1000, "s")
		pending_start = false
		_start_match()
		return
	if (Time.get_ticks_msec() - peer_wait_start) / 1000.0 > 20.0:
		print("EXPERIMENT: peer wait TIMEOUT, starting anyway")
		pending_start = false
		_start_match()

func _start_match() -> void:
	# The match must start FIRST: start_net_host() creates the codec
	# (CommManager) and calls begin_metrics(). Applying codec config before
	# that fails with "no active optimized codec".
	main.start_net_host()
	# experiment controls (validated; failures print + continue)
	var flags := {}
	for f in str(cfg["flags"]).split(","):
		match f.strip_edges():
			"delta":
				flags["delta_enabled"] = true
			"nodelta":
				flags["delta_enabled"] = false
			"dedup":
				flags["dedup_enabled"] = true
			"nodedup":
				flags["dedup_enabled"] = false
			"compression":
				flags["compression_enabled"] = true
			"nocompression":
				flags["compression_enabled"] = false
			"priority":
				flags["priority_enabled"] = true
			"nopriority":
				flags["priority_enabled"] = false
			"partial":
				flags["partial_enabled"] = true
			"nopartial":
				flags["partial_enabled"] = false
	print("EXPERIMENT: netcfg=", JSON.stringify(main.apply_net_config(
		{"update_hz": float(cfg["rate"]), "budget_kbps": float(cfg["budget"]),
		 "max_packet": int(cfg["mpsize"])})))
	if not flags.is_empty():
		flags["medium_pct"] = int(cfg["medpct"])
		flags["low_pct"] = int(cfg["lowpct"])
		print("EXPERIMENT: prio=", JSON.stringify(main.apply_opt_config(flags)))
	# SIMULATED link (research): shaped BEFORE the match starts so the
	# match metadata is labeled 'simulated' from its first sample
	var sim: Dictionary = main.configure_net_sim(float(cfg["lat"]), float(cfg["jit"]),
		float(cfg["loss"]), float(cfg["sim_bw"]))
	print("EXPERIMENT: simlink=", JSON.stringify(sim))
	main.time_left = float(cfg["dur"])
	main.experiment_id = str(cfg["exp"])
	main.monitor.base_url = "http://127.0.0.1:%d" % int(cfg["mon"])
	main.monitor_events.append({"type": "EXPERIMENT_STARTED",
		"t": Time.get_ticks_msec() / 1000.0, "match_id": main.match_id,
		"detail": str(cfg["exp"])})
	print("EXPERIMENT: started mode=%s seed=%d dur=%ds exp=%s rate=%s budget=%s" % [
		str(cfg["mode"]), int(cfg["seed"]), int(cfg["dur"]), str(cfg["exp"]),
		str(cfg["rate"]), str(cfg["budget"])])

## A second, REAL peer process: joins over WebSocket so the host measures
## genuine RTT / ping / packet loss instead of reporting N/A.
func _spawn_peer(code: String) -> void:
	var exe := OS.get_executable_path()
	var args := PackedStringArray([
		"--headless", "--path", ProjectSettings.globalize_path("res://").trim_suffix("/"),
		"--script", "res://tests/ExperimentRun.gd", "--",
		"--role=guest", "--code=" + code, "--dur=" + str(cfg["dur"]),
		"--exp=" + str(cfg["exp"]), "--mon=" + str(cfg["mon"]),
		"--port=" + str(cfg["port"])])
	var pid := OS.create_process(exe, args)
	print("EXPERIMENT: peer spawned pid=", pid, " exe=", exe)

## Guest role: real WebSocket client. It DOES stream its own device
## telemetry (that is how the room session sees each device's FPS/ping);
## it simply is not the measured host node.
func _setup_guest() -> void:
	main.settings.touch_mode = 0
	main._start_net_join("127.0.0.1", int(cfg["port"]), str(cfg["code"]))
	print("EXPERIMENT: guest joining code=", str(cfg["code"]))

func _finish() -> void:
	Input.action_release("move_forward")
	Input.action_release("fire")
	if str(cfg["role"]) == "guest":
		print("EXPERIMENT_DONE: guest joined=", main.net_mode == "client",
			" id=", main.my_net_id, " puppets=", main.puppets.size())
		return
	var summary: Dictionary = main.metrics.summary(main.match_meta)
	summary["experiment_id"] = str(cfg["exp"])
	summary["net_cfg"] = {"update_hz": main.net_update_hz,
		"budget_kbps": main.net_budget_kbps, "budget_skipped": main.bw_skipped,
		"attempts": main.bw_attempts, "sent_packets": main.bw_sent_packets,
		"effective_hz": float(main.bw_sent_packets) / maxf(0.001, main.metrics.elapsed),
		"link": ("simulated: " + main.net_sim.describe()) if (main.net_sim != null and main.net_sim.enabled) else "real",
		"sim_stats": (main.net_sim.stats() if (main.net_sim != null and main.net_sim.enabled) else {})}
	if main.comm and main.comm.opt:
		summary["codec"] = (main.comm.opt as OptimizedCodec).stats()
	print("EXPERIMENT_DONE: ", JSON.stringify(summary))
	if main != null and main.monitor != null:
		main.monitor.flush() # final push; drained by the flush loop
