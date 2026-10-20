# Seed determinism: same map_seed -> identical static layout (covers +
# spawns), different seed -> (almost surely) different layout.
# Run: godot --headless --path <project> --script res://tests/SeedSim.gd
extends SceneTree

var results: Array = []

func _build(seed_value: int) -> Dictionary:
	var holder := Node3D.new()
	root.add_child(holder)
	var built: Dictionary = ArenaBuilder.build(holder, seed_value)
	var covers: Array = (built["covers"] as Array).duplicate()
	var sb: Array = (built["spawns_blue"] as Array).duplicate()
	holder.queue_free()
	return {"covers": covers, "spawns": sb}

func _sig(b: Dictionary) -> String:
	var parts: Array = []
	for v in b["covers"]:
		parts.append("%0.3f,%0.3f" % [(v as Vector3).x, (v as Vector3).z])
	for v in b["spawns"]:
		parts.append("%0.2f,%0.2f" % [(v as Vector3).x, (v as Vector3).z])
	return "|".join(parts)

func _initialize() -> void:
	var a := _build(12345)
	var b := _build(12345)
	var c := _build(99999)
	_check("same seed identical", _sig(a) == _sig(b), "")
	_check("covers nonempty", (a["covers"] as Array).size() > 20, "n=%d" % (a["covers"] as Array).size())
	_check("diff seed differs", _sig(a) != _sig(c), "")
	var fails := 0
	for r in results:
		if not r:
			fails += 1
	print("SEEDSIM: DONE %d/%d passed" % [results.size() - fails, results.size()])
	quit()

func _check(name: String, ok: bool, detail: String) -> void:
	results.append(ok)
	print("SEEDSIM: [%s] %s %s" % ["PASS" if ok else "FAIL", name, ("(" + detail + ")") if detail != "" else ""])
