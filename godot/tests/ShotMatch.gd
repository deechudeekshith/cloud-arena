# In-match screenshot test. Starts a match, keeps mouse VISIBLE (does not
# disturb the desktop), teleports the player to the plaza edge aimed at the
# hotspot, lets bots converge, captures FP + HUD view, quits.
# Run: DISPLAY=:0 godot --path <project> --resolution 960x600 --script res://tests/ShotMatch.gd
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
		main.start_match()
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		print("SHOTMATCH: started")
	if frames > 5 and main.phase == 2 and not placed:
		placed = true
	if placed and frames % 10 == 0:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_stage()
	if frames == 300:
		_shot("/tmp/opencode/shots/hp_full.png")
	if frames == 414:
		# clean slate for the beauty shot, then a staged 70-dmg hit so the
		# ghost bar + red gradient + low-HP vignette are all visible
		var pr = main.player
		if pr:
			pr.respawn_at(Vector3(0, 1.1, 17), 0.0)
			main.hud.show_respawn(0.0)
	if frames == 420: # ~7s of battle after staging
		# pose two bots in view to prove in-world humanoids render
		var b1 = main._by_id(4)
		var b2 = main._by_id(1)
		if b1 and not bool(b1.get("dead")):
			b1.global_position = Vector3(1.6, 1.05, 9.5)
			b1.rotation.y = PI
			b1.set("_yaw", PI)
		if b2 and not bool(b2.get("dead")):
			b2.global_position = Vector3(-1.8, 1.05, 10.5)
			b2.rotation.y = PI
			b2.set("_yaw", PI)
		var pp = main.player
		if pp and not bool(pp.get("dead")):
			pp.apply_hit(70.0, 5, false, pp.global_position, Vector3.UP)
		Input.action_press("fire") # hold fire through the shots (flash/tracer/shell)
	if frames == 432:
		_shot("/tmp/opencode/shots/fp.png")
	if frames == 436:
		_shot("/tmp/opencode/shots/fp_fire.png")
	if frames == 440:
		Input.action_release("fire")
	if frames >= 460:
		print("SHOTMATCH: DONE scores=", main.team_scores)
		return true
	return false

func _stage() -> void:
	# stage the player view: plaza edge, aimed at center hotspot
	var p = main.player
	if p and not bool(p.get("dead")):
		p.global_position = Vector3(0, 1.1, 17)
		p.set("yaw", 0.0)
		p.set("pitch", -0.04)
		p.rotation.y = 0.0
		(p.get_node("Head") as Node3D).rotation.x = -0.04

func _shot(path: String) -> void:
	await process_frame
	await process_frame
	var img := root.get_texture().get_image()
	var err := img.save_png(path)
	print("SHOTMATCH: ", path, " err=", err, " size=", img.get_size())
