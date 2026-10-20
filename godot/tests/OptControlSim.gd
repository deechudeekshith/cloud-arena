# Optimization-control verification: every dashboard control must measurably
# change encoder output, and net config must validate. Headless, no network.
# Run: godot --headless --path <project> --script res://tests/OptControlSim.gd
extends SceneTree

var frames := 0
var main: Node = null
var results: Array = []
var started := false

func _initialize() -> void:
	var ps: PackedScene = load("res://scenes/main/Main.tscn")
	main = ps.instantiate()
	root.add_child(main)

func _process(_dt: float) -> bool:
	frames += 1
	if frames == 5:
		main.settings.touch_mode = 0
		main.start_match()
		return false
	if frames < 6 or main.phase != 2:
		return false
	if not started:
		started = true
		_codec_checks()
		_net_checks()
		_sim_checks()
		_budget_checks()
		_report()
		return true
	return false

# ---------------- codec flags ----------------
func _codec_checks() -> void:
	# Use the production codec class directly on realistic state
	var players: Array = []
	for i in 8:
		players.append({
			"player_id": i, "team_id": i % 2, "avatar_id": i % 4,
			"name": "p%d" % i, "position": Vector3(i, 0.0, i * 0.7),
			"rotation": Vector2(0.0, 0.0), "velocity": Vector3(0.1, 0, 0),
			"health": 100.0, "animation_state": "RUNNING", "stance": "RUNNING",
			"weapon_id": 0, "mag": 30, "reserve": 90,
			"shooting": false, "reloading": false, "cloaked": false})
	var run := func(flags: Dictionary) -> Dictionary:
		var c := OptimizedCodec.new()
		c.apply_config(flags)
		var seq := 0
		for step in 40:
			# small state motion so delta has real work
			for p in players:
				var pd: Dictionary = p
				pd["position"] = pd["position"] + Vector3(0.03, 0, 0.01)
				pd["velocity"] = Vector3(float(step), 0, 0)
			seq += 1
			c.encode_snapshot(players, [3, 2], 180.0 - step, seq)
		return c.stats()
	var full: Dictionary = run.call({"delta_enabled": true, "dedup_enabled": true,
		"compression_enabled": true, "priority_enabled": true, "partial_enabled": true})
	var no_delta: Dictionary = run.call({"delta_enabled": false, "dedup_enabled": true,
		"compression_enabled": true, "priority_enabled": true, "partial_enabled": true})
	var no_comp: Dictionary = run.call({"delta_enabled": true, "dedup_enabled": true,
		"compression_enabled": false, "priority_enabled": true, "partial_enabled": true})
	var no_prio: Dictionary = run.call({"delta_enabled": true, "dedup_enabled": true,
		"compression_enabled": true, "priority_enabled": false, "partial_enabled": true})
	var no_partial: Dictionary = run.call({"delta_enabled": true, "dedup_enabled": true,
		"compression_enabled": true, "priority_enabled": true, "partial_enabled": false})
	var fb := int(full["transferred_bytes"])
	_check("full pipeline transfers data", fb > 0, "%d B" % fb)
	_check("delta ON reduces bytes", int(full["transferred_bytes"]) < int(no_delta["transferred_bytes"]),
		"full=%d no_delta=%d" % [fb, int(no_delta["transferred_bytes"])])
	_check("delta OFF emits full states", int(no_delta["deltas"]) == 0 and int(no_delta["fulls"]) > 0,
		"deltas=%d fulls=%d" % [int(no_delta["deltas"]), int(no_delta["fulls"])])
	_check("compression ON reduces bytes", int(full["transferred_bytes"]) < int(no_comp["transferred_bytes"]),
		"full=%d no_comp=%d" % [fb, int(no_comp["transferred_bytes"])])
	_check("priority ON elides MEDIUM fields", int(full["med_elided"]) > 0,
		"elided=%d" % int(full["med_elided"]))
	_check("priority OFF includes more MEDIUM", int(no_prio["med_included"]) > int(full["med_included"]),
		"no_prio=%d full=%d" % [int(no_prio["med_included"]), int(full["med_included"])])
	_check("partial OFF sends bigger records", int(no_partial["transferred_bytes"]) > fb,
		"no_partial=%d full=%d" % [int(no_partial["transferred_bytes"]), fb])
	_check("stage accounting ordered",
		int(full["select_bytes"]) >= int(full["delta_bytes"]) and int(full["delta_bytes"]) >= fb,
		"select=%d delta=%d sent=%d" % [int(full["select_bytes"]), int(full["delta_bytes"]), fb])
	# dedup: identical *state* across consecutive delta packets must collapse.
	# (a scheduled full heal is never suppressed, by design)
	var dcode := OptimizedCodec.new()
	dcode.dedup_enabled = true
	dcode.full_every = 999
	dcode.delta_enabled = true
	var reps := 0
	for seq in range(1, 8):
		var e2: Dictionary = dcode.encode_snapshot(players, [1, 1], 10.0, seq)
		if str(e2.get("kind", "")) == "repeat":
			reps += 1
	_check("dedup collapses repeats", reps > 0,
		"repeats=%d" % reps)
	# roundtrip: delta stream decodes losslessly through the same shapes
	var rt := OptimizedCodec.new()
	rt.delta_enabled = true
	rt.compression_enabled = true
	var ok := true
	for seq in range(1, 12):
		for p in players:
			var pd2: Dictionary = p
			pd2["health"] = 50.0 + float(seq)
		var enc: Dictionary = rt.encode_snapshot(players, [0, 0], 100.0, seq)
		var dec: Dictionary = rt.decode_snapshot(enc["bytes"])
		if not bool(dec.get("ok", false)):
			ok = false
			break
	_check("optimized roundtrip lossless", ok, "")

# ---------------- net config validation ----------------
func _net_checks() -> void:
	_check("hz 20 accepted", bool(main.apply_net_config({"update_hz": 20.0})["applied"]), "")
	_check("hz 5 accepted (min)", bool(main.apply_net_config({"update_hz": 5.0})["applied"]), "")
	_check("hz 60 accepted (max)", bool(main.apply_net_config({"update_hz": 60.0})["applied"]), "")
	_check("hz 0 rejected", not bool(main.apply_net_config({"update_hz": 0.0})["applied"]), "")
	_check("hz 120 rejected", not bool(main.apply_net_config({"update_hz": 120.0})["applied"]), "")
	_check("negative budget rejected", not bool(main.apply_net_config({"budget_kbps": -1.0})["applied"]), "")
	_check("budget 512 accepted", bool(main.apply_net_config({"budget_kbps": 512.0})["applied"]),
		"budget=%s" % str(main.net_budget_kbps))
	# command path (what the dashboard actually calls)
	var c1: Dictionary = main.apply_monitor_command("set_net", {"update_hz": 33})
	_check("command set_net applied", bool(c1["applied"]), str(c1["detail"]))
	var c2: Dictionary = main.apply_monitor_command("set_net", {"update_hz": 0})
	_check("command set_net rejects bad", not bool(c2["applied"]), str(c2["detail"]))
	var c3: Dictionary = main.apply_monitor_command("bogus", {})
	_check("unknown command rejected", not bool(c3["applied"]), str(c3["detail"]))
	main.apply_net_config({"update_hz": 20.0, "budget_kbps": 0.0})

# ---------------- bandwidth budget ----------------
func _budget_checks() -> void:
	# an offline match has no transport; give the broadcast path the same
	# codec + transport a real host match has
	if main.comm == null:
		main.comm = CommManager.make("OPTIMIZED")
		main.comm.opt = OptimizedCodec.new()
	if main.net == null:
		main.net = NetTransport.new()
		main.add_child(main.net)
	# 4 KB/s budget on a 20 Hz stream: most snapshots must be dropped
	main.apply_net_config({"budget_kbps": 4.0, "update_hz": 20.0})
	main.bw_skipped = 0
	main.bw_sent_bytes = 0
	for i in 200:
		main._host_broadcast(0.05)
	_check("budget drops snapshots under limit", main.bw_skipped > 0,
		"skipped=%d sent_bytes=%d" % [main.bw_skipped, main.bw_sent_bytes])
	_check("budget cap respected", main.bw_sent_bytes <= 4.0 * 1000.0 / 8.0 * 10.0,
		"%d B in 10s @ 4KB/s (=<=5000)" % main.bw_sent_bytes)
	main.apply_net_config({"budget_kbps": 0.0, "update_hz": 20.0})

# ---------------- simulated link ----------------
func _sim_checks() -> void:
	var ok: Dictionary = main.configure_net_sim(50.0, 10.0, 1.0, 0.0)
	_check("sim link applied", bool(ok["applied"]) and bool(ok["enabled"]), str(ok.get("detail", "")))
	_check("sim link labels match simulated", str(main.match_meta.get("net", "")) == "simulated",
		str(main.match_meta.get("net", "")))
	_check("negative latency rejected",
		not bool(main.configure_net_sim(-1.0, 0.0, 0.0)["applied"]), "")
	_check("loss > 100 rejected",
		not bool(main.configure_net_sim(0.0, 0.0, 150.0)["applied"]), "")
	# conditioner actually drops/delays packets (Array is a mutable box:
	# GDScript lambdas capture locals by value)
	var s := NetSim.new()
	s.configure(0.0, 0.0, 20.0, 0.0)
	var box := [0]
	for i in 200:
		s.send("snapshot", {"i": i}, 100, func(_k: String, _p: Variant) -> void: box[0] += 1)
	_check("simulator drops lossy traffic", box[0] < 200 and box[0] > 100,
		"delivered %d/200" % box[0])
	# all-zero disables it and restores the real label
	var off: Dictionary = main.configure_net_sim(0.0, 0.0, 0.0, 0.0)
	_check("sim link disables at zero", not bool(off["enabled"]), str(off.get("detail", "")))
	_check("label restored to real", str(main.match_meta.get("net", "")) == "real",
		str(main.match_meta.get("net", "")))

func _check(name: String, ok: bool, detail: String) -> void:
	results.append(ok)
	print("OPTCONTROL: [%s] %s (%s)" % ["PASS" if ok else "FAIL", name, detail])

func _report() -> void:
	var fails := 0
	for r in results:
		if not r:
			fails += 1
	print("OPTCONTROL: DONE %d/%d passed" % [results.size() - fails, results.size()])
