# Touch layout proof: forced touch UI, FP view with all buttons visible.
# Run: DISPLAY=:0 godot --path <project> --resolution 1280x720 --script res://tests/ShotTouch.gd
extends SceneTree

var frames := 0
var main: Node = null
var placed := false

func _initialize() -> void:
	var ps: PackedScene = load("res://scenes/main/Main.tscn")
	main = ps.instantiate()
	root.add_child(main)

func _process(_dt: float) -> bool:
	frames += 1
	if frames == 5:
		main.settings.touch_mode = 1
		main.start_match()
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if frames > 5 and main.phase == 2 and not placed:
		placed = true
	if placed and frames % 10 == 0:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		var p = main.player
		if p and not bool(p.get("dead")):
			p.global_position = Vector3(0, 1.1, 17)
			p.set("yaw", 0.0)
			p.set("pitch", -0.04)
			p.rotation.y = 0.0
	if frames == 300:
		var img := root.get_texture().get_image()
		print("SHOTTOUCH: err=", img.save_png("/tmp/opencode/shots/touch_ui.png"), " size=", img.get_size())
	if frames >= 320:
		print("SHOTTOUCH: DONE touch_active=", main.touch_active())
		return true
	return false
