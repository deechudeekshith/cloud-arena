# Stance visual proof: third-person shots of prone-under-fence and
# crouch-at-gate with the movement debug panel visible.
# Run: DISPLAY=:0 godot --path <project> --resolution 960x600 --script res://tests/ShotStance.gd
extends SceneTree

var frames := 0
var main: Node = null
var cam: Camera3D
var playing_since := -1
var did_prone := false
var did_crouch := false

func _initialize() -> void:
	var ps: PackedScene = load("res://scenes/main/Main.tscn")
	main = ps.instantiate()
	root.add_child(main)
	cam = Camera3D.new()
	cam.fov = 55.0
	cam.far = 400.0
	main.add_child(cam)

func _process(_dt: float) -> bool:
	frames += 1
	if frames == 5:
		main.start_match()
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if main.phase == 2 and playing_since < 0:
		playing_since = frames
		for c in main.combatants:
			if c != main.player and is_instance_valid(c):
				c.set_physics_process(false) # freeze bots for clean staging
		main.player.health.max_hp = 100000.0
		main.player.health.hp = 100000.0
	if playing_since < 0:
		return false
	cam.current = true
	var el: int = frames - playing_since
	if el == 10 and not did_prone:
		did_prone = true
		_stage(1.5, 42.6, true, false)
	if el == 100 and did_prone:
		_snap(Vector3(1.5, 0.7, 45.8), Vector3(1.5, 0.25, 42.6), "/tmp/opencode/shots/tp_prone.png")
		_stage(1.5, 46.6, false, true)
	if el == 190:
		_snap(Vector3(1.5, 2.2, 42.4), Vector3(1.5, 0.9, 46.6), "/tmp/opencode/shots/tp_crouch.png")
	if el >= 210:
		print("SHOTSTANCE: DONE")
		return true
	return false

func _stage(x: float, z: float, prone: bool, crouch: bool) -> void:
	var p = main.player
	p.global_position = Vector3(x, 0.05, z)
	p.velocity = Vector3.ZERO
	p.rotation.y = PI
	p.set("yaw", PI)
	p.set("want_prone", prone)
	p.set("want_crouch", crouch)
	p.set_body_visible(true)

func _snap(cam_pos: Vector3, look: Vector3, path: String) -> void:
	var p = main.player
	var bv = p.get("body_visual")
	var parts = p.get("body_parts")
	var headpos := Vector3.ZERO
	var nvis := 0
	var ntotal := 0
	if parts is Dictionary:
		for k in (parts as Dictionary).keys():
			var part = (parts as Dictionary)[k] as Node3D
			if part:
				for ch in part.get_children():
					if ch is MeshInstance3D:
						ntotal += 1
						if (ch as MeshInstance3D).visible:
							nvis += 1
						print("SHOTSTANCE: mesh ", part.name, "/", (ch as Node3D).name,
							" at ", (ch as Node3D).global_position)
				if str(k) == "Head":
					headpos = part.global_position
	print("SHOTSTANCE: cam=", cam.global_position, " rot=", cam.global_rotation)
	print("SHOTSTANCE: diag pos=", p.global_position, " dead=", p.get("dead"),
		" stance=", p.get_stance_info(), " blend=", p.get("_prone_blend"),
		" bodyvis=", (bv as Node3D).visible if bv else false,
		" bodyrot=", (bv as Node3D).rotation if bv else Vector3.ZERO,
		" bodypos=", (bv as Node3D).position if bv else Vector3.ZERO,
		" head=", headpos, " meshes=", nvis, "/", ntotal)
	await process_frame
	await process_frame
	var img := root.get_texture().get_image()
	print("SHOTSTANCE: ", path, " err=", img.save_png(path))
