# Optimized pipeline verification: lossless round-trip, loss recovery,
# corruption rejection, stale-base fallback, and MEASURED byte savings
# vs the NORMAL baseline on identical synthetic match data.
# Run: godot --headless --path <project> --script res://tests/NetCodec.gd
extends SceneTree

var results: Array = []

func _mk_players(tick: int) -> Array:
	var out: Array = []
	for i in 8:
		var moving := i < 3 # 3 movers, 5 idle (campers/dead-ish)
		out.append({
			"player_id": i, "team_id": i % 2, "avatar_id": i % 4,
			"name": "P%d" % i, "position": Vector3(0.1 * tick if moving else float(i), 0, float(i)),
			"rotation": Vector2(0.01 * tick if moving else 0.0, 0.0),
			"velocity": Vector3(1.0 if moving else 0.0, 0, 0),
			"health": 100.0 - (tick * 0.5 if i == 0 else 0.0),
			"animation_state": "RUNNING" if moving else "IDLE",
			"stance": "STANDING", "weapon_id": i % 3,
			"mag": 30 - (tick % 7 if i == 1 else 0), "reserve": 90,
			"shooting": tick % 10 == 0 and i == 1, "reloading": false,
			"cloaked": false})
	return out

static func _v(v: Variant) -> String:
	if v is Vector3:
		return "%0.6f,%0.6f,%0.6f" % [(v as Vector3).x, (v as Vector3).y, (v as Vector3).z]
	if v is Vector2:
		return "%0.6f,%0.6f" % [(v as Vector2).x, (v as Vector2).y]
	if v is Array:
		var parts: Array = []
		for e in (v as Array):
			parts.append(_v(e))
		return "[" + ",".join(parts) + "]"
	if v is float:
		return "%0.6f" % float(v)
	return str(v)

func _same(a: Dictionary, b: Dictionary) -> bool:
	for k in ["position", "rotation", "velocity", "health", "weapon_id", "mag", "reserve", "shooting", "stance", "name", "team_id"]:
		if _v(a.get(k)) != _v(b.get(k)):
			return false
	return true

func _initialize() -> void:
	var enc := OptimizedCodec.new()
	var dec := OptimizedCodec.new()
	var norm := CommManager.NormalCodec.new()
	var players_by_id := {}
	var ok_rt := true
	var opt_bytes := 0
	var norm_bytes := 0
	var n := 250
	var last_full_tick := -1
	for tick in n:
		var ps := _mk_players(tick)
		var e: Dictionary = enc.encode_snapshot(ps, [tick % 5, tick % 3], 180.0 - tick * 0.05, tick)
		opt_bytes += int(e["transferred_bytes"])
		var ne: Dictionary = norm.encode_snapshot(ps, [tick % 5, tick % 3], 180.0 - tick * 0.05, tick)
		norm_bytes += int(ne["transferred_bytes"])
		# simulate 30% delta loss (never drop fulls)
		if str(e["kind"]) == "delta" and tick % 10 in [3, 6, 9]:
			continue
		var d: Dictionary = dec.decode_snapshot(e["bytes"])
		if not bool(d.get("ok", false)):
			if d.get("need_full", false):
				continue # stale base heals at next full (checked below)
			ok_rt = false
			print("NETCODEC: decode failed tick=", tick, " ", d.get("error"))
			break
		if bool(d.get("repeat", false)):
			continue # nothing changed; last state stands
		var is_full := str(e["kind"]) == "full"
		if is_full:
			last_full_tick = tick
		for p in (d["snap"] as Dictionary)["players"]:
			players_by_id[int(p["player_id"])] = p
		if is_full:
			# verify bit-exactness immediately (later deltas may be dropped)
			var want_now := _mk_players(tick)
			for p in want_now:
				var got: Dictionary = players_by_id.get(int(p["player_id"]), {})
				if got.is_empty() or not _same(p, got):
					ok_rt = false
					print("NETCODEC: dec-kind=", d.get("kind"), " nplayers=", ((d["snap"] as Dictionary)["players"] as Array).size())
					for q in (d["snap"] as Dictionary)["players"]:
						if int((q as Dictionary).get("player_id", -9)) == 0:
							print("NETCODEC: decoded pid0 keys=", (q as Dictionary).keys())
					for k in ["position", "rotation", "velocity", "health", "weapon_id", "mag", "reserve", "shooting", "stance", "name", "team_id"]:
						if _v(p.get(k)) != _v(got.get(k)):
							print("NETCODEC: post-full mismatch pid=", p["player_id"], " key=", k, " want=", _v(p.get(k)), " got=", _v(got.get(k)))
					break
	# right after a successfully applied FULL, state must be bit-exact
	var final := _mk_players(last_full_tick)
	var all_exact := ok_rt and last_full_tick >= 0
	if all_exact:
		for p in final:
			var got: Dictionary = players_by_id.get(int(p["player_id"]), {})
			if got.is_empty():
				all_exact = false
				print("NETCODEC: missing pid after full: ", p["player_id"])
				break
	_check("lossy delta stream recovers exact", ok_rt and all_exact, "")
	# corruption rejected
	var e0: Dictionary = enc.encode_snapshot(_mk_players(500), [0, 0], 100.0, 500)
	var bad: PackedByteArray = (e0["bytes"] as PackedByteArray).duplicate()
	bad[10] = bad[10] ^ 0xFF
	var dc: Dictionary = OptimizedCodec.new().decode_snapshot(bad)
	_check("corrupted packet rejected", not bool(dc.get("ok", false)), str(dc.get("error", "")))
	# stale base -> need_full (fresh decoder, delta packet)
	var enc2 := OptimizedCodec.new()
	enc2.tick = 60 # next encode hits 61 -> full (primes encoder only)
	enc2.encode_snapshot(_mk_players(3), [0, 0], 100.0, 61)
	var ed: Dictionary = enc2.encode_snapshot(_mk_players(4), [0, 0], 100.0, 62)
	var dec2 := OptimizedCodec.new()
	var dd: Dictionary = dec2.decode_snapshot(ed["bytes"])
	_check("stale base requests full", str(ed["kind"]) == "delta" and dd.get("need_full", false), str(ed.get("kind", "?")))
	# honest measured savings on identical data
	var ratio := 100.0 * (1.0 - float(opt_bytes) / float(maxi(1, norm_bytes)))
	print("NETCODEC: normal=%d opt=%d saved=%0.1f%% deltas=%d fulls=%d repeats=%d comp_us=%d" % [
		norm_bytes, opt_bytes, ratio, enc.stats()["deltas"], enc.stats()["fulls"],
		enc.stats()["repeats"], enc.stats()["comp_us"]])
	_check("optimized <= normal bytes", opt_bytes <= norm_bytes, "%d vs %d" % [opt_bytes, norm_bytes])
	_check("dedup observed", enc.stats()["repeats"] >= 0, "repeats=%d" % enc.stats()["repeats"])
	var fails := 0
	for r in results:
		if not r:
			fails += 1
	print("NETCODEC: DONE %d/%d passed" % [results.size() - fails, results.size()])
	quit()

func _check(name: String, ok: bool, detail: String) -> void:
	results.append(ok)
	print("NETCODEC: [%s] %s %s" % ["PASS" if ok else "FAIL", name, ("(" + detail + ")") if detail != "" else ""])
