# Rendered screenshot test. Boots Main in MENU state (no mouse capture),
# captures orbit-arena view + main-menu view, saves PNGs, quits.
# Run: DISPLAY=:0 godot --path <project> --resolution 960x600 --script res://tests/Shot.gd
extends SceneTree

var frames := 0
var main: Node = null

func _initialize() -> void:
	var ps: PackedScene = load("res://scenes/main/Main.tscn")
	main = ps.instantiate()
	root.add_child(main)

func _process(_dt: float) -> bool:
	frames += 1
	if frames == 60:
		main.menus.hide_all()
	if frames == 90:
		_shot("/tmp/opencode/shots/arena.png")
	if frames == 100:
		main.menus.show_screen("MAIN")
	if frames == 130:
		_shot("/tmp/opencode/shots/menu.png")
	if frames >= 150:
		print("SHOT: DONE")
		return true
	return false

func _shot(path: String) -> void:
	await process_frame
	await process_frame
	var img := root.get_texture().get_image()
	var err := img.save_png(path)
	print("SHOT: ", path, " err=", err, " size=", img.get_size())
