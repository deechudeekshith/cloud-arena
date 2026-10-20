# Metrics + storage + dashboard verification: play two short offline
# matches to completion (forced end), check saved datasets, render the
# dashboard browser/match/compare screens without crashing.
# Run: godot --headless --path <project> --script res://tests/MatchStoreSim.gd
extends SceneTree

var frames := 0
var main: Node = null
var results: Array = []
var stage := 0
var ids: Array = []

func _initialize() -> void:
	var ps: PackedScene = load("res://scenes/main/Main.tscn")
	main = ps.instantiate()
	root.add_child(main)

func _process(_dt: float) -> bool:
	frames += 1
	if frames == 5:
		main.start_match()
		stage = 1
		return false
	if stage == 1 and main.phase == 2:
		# let metrics accumulate a few samples, then force match end
		stage = 2
	if stage == 2 and main.metrics.samples.size() >= 6:
		main.end_match()
		stage = 3
	if stage == 3 and frames % 30 == 0:
		ids.append(main.last_match_id)
		if ids.size() >= 2:
			_verify()
			return true
		main.to_menu()
		main.start_match()
		stage = 1
	return false

func _verify() -> void:
	_check("two matches saved", ids.size() == 2 and str(ids[0]) != "" and str(ids[1]) != "", str(ids))
	for id in ids:
		var s: Dictionary = main.storage.load_summary(str(id))
		_check("summary " + str(id), not s.is_empty() and int(s.get("samples", 0)) >= 6,
			"samples=%s fps=%s" % [str(s.get("samples", "?")), str(s.get("avg_fps", "?"))])
		var rows: Array = main.storage.load_rows(str(id))
		_check("csv rows " + str(id), rows.size() >= 6, "rows=%d" % rows.size())
		var m: Dictionary = MatchStorage.LocalProvider.load_meta(str(id))
		_check("metadata " + str(id), str(m.get("match_id", "")) == str(id)
			and m.has("map_seed") and m.has("mode"), str(m.get("mode", "?")))
	# dashboard logic (headless: build screens, no rendering needed)
	main.dash.show_browser()
	_check("browser lists matches", main.storage.list_matches().size() >= 2, "")
	main.dash.show_match(str(ids[0]))
	_check("match screen builds", true, "")
	main.dash.show_compare(str(ids[0]), str(ids[1]))
	_check("compare builds", true, "")
	var fails := 0
	for r in results:
		if not r:
			fails += 1
	print("STORESIM: DONE %d/%d passed" % [results.size() - fails, results.size()])

func _check(name: String, ok: bool, detail: String) -> void:
	results.append(ok)
	print("STORESIM: [%s] %s %s" % ["PASS" if ok else "FAIL", name, ("(" + detail + ")") if detail != "" else ""])
