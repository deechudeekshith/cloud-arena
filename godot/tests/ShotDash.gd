# Dashboard visual proof: play ~15s for real samples, end match, capture
# match view (stats + 8 graphs) and comparison view.
# Run: DISPLAY=:0 godot --path <project> --resolution 1280x720 --script res://tests/ShotDash.gd
extends SceneTree

var frames := 0
var main: Node = null
var ended := false

func _initialize() -> void:
	var ps: PackedScene = load("res://scenes/main/Main.tscn")
	main = ps.instantiate()
	root.add_child(main)

func _process(_dt: float) -> bool:
	frames += 1
	if frames == 5:
		main.start_match()
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if main.phase == 2 and not ended and frames > 1000:
		ended = true
		main.end_match()
		main.dash.show_match(main.last_match_id)
	if ended and frames > 1030 and frames < 1060:
		pass
	if ended and frames == 1060:
		_shot("/tmp/opencode/shots/dash_match.png")
	if ended and frames == 1070:
		var ms: Array = main.storage.list_matches()
		if ms.size() >= 2:
			main.dash.show_compare(str(ms[0]["id"]), str(ms[1]["id"]))
	if ended and frames == 1100:
		_shot("/tmp/opencode/shots/dash_compare.png")
	if ended and frames >= 1120:
		print("SHOTDASH: DONE id=", main.last_match_id)
		return true
	return false

func _shot(path: String) -> void:
	await process_frame
	await process_frame
	var img := root.get_texture().get_image()
	print("SHOTDASH: ", path, " err=", img.save_png(path))
