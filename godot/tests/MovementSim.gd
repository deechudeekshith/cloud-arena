# Movement verification: stance blocking/passing + sprint burst, headless.
# Fence z=44 (0.6 gap, prone-only). Gate z=48 (1.2 gap, crouch+).
# Run: godot --headless --path <project> --script res://tests/MovementSim.gd
extends SceneTree

var frames := 0
var main: Node = null
var stage := 0
var stage_frame := 0
var results: Array = []
var sprint_seen := false
var sprint_speed := 0.0

func _initialize() -> void:
	var ps: PackedScene = load("res://scenes/main/Main.tscn")
	main = ps.instantiate()
	root.add_child(main)

func _process(_dt: float) -> bool:
	frames += 1
	if frames == 5:
		main.start_match()
		# invincible test dummy (damage still registers, death never triggers)
		main.player.health.max_hp = 100000.0
		main.player.health.hp = 100000.0
		_place(1.5, 41.0, PI)
		stage = 1
		stage_frame = frames
		print("MOVSIM: stage 1 stand-blocked @ fence")
		return false
	if frames < 6 or main.phase != 2:
		return false
	var p = main.player
	match stage:
		1: # standing into fence -> must stay z<43.4
			Input.action_press("move_forward")
			if frames - stage_frame > 500:
				Input.action_release("move_forward")
				_check("stand blocked by fence", p.global_position.z < 43.4,
					"z=%0.2f stance=%s" % [p.global_position.z, p.get_stance_info()["state"]])
				p.request_prone_toggle()
				stage = 2
				stage_frame = frames
				print("MOVSIM: stage 2 prone-pass @ fence")
		2: # prone under fence -> must cross z>45
			if frames - stage_frame > 60:
				Input.action_press("move_forward")
			if frames - stage_frame > 1200:
				Input.action_release("move_forward")
				_check("prone passes fence", p.global_position.z > 45.0,
					"z=%0.2f stance=%s" % [p.global_position.z, p.get_stance_info()["state"]])
				_place(1.5, 46.0, PI)
				# from prone -> crouch
				p.request_crouch_toggle()
				stage = 3
				stage_frame = frames
				print("MOVSIM: stage 3 crouch-pass @ gate")
		3: # crouch through gate z=48 -> must cross z>49
			if frames - stage_frame > 60:
				Input.action_press("move_forward")
			if frames - stage_frame > 1200:
				Input.action_release("move_forward")
				_check("crouch passes gate", p.global_position.z > 49.0,
					"z=%0.2f stance=%s" % [p.global_position.z, p.get_stance_info()["state"]])
				_place(0.0, 20.0, -PI * 0.5)
				# ensure standing
				p.want_prone = false
				p.want_crouch = false
				stage = 4
				stage_frame = frames
				print("MOVSIM: stage 4 sprint burst")
		4: # SHIFT+W burst
			Input.action_press("move_forward")
			if frames - stage_frame == 30:
				Input.action_press("sprint")
			if frames - stage_frame == 32:
				Input.action_release("sprint")
			if frames - stage_frame > 32 and frames - stage_frame < 120:
				if str(p.get_stance_info()["state"]) == "SPRINTING":
					sprint_seen = true
					sprint_speed = maxf(sprint_speed, float(p.get_stance_info()["speed"]))
			if frames - stage_frame > 400:
				Input.action_release("move_forward")
				_check("sprint burst fired", sprint_seen, "peak=%0.2f" % sprint_speed)
				_check("sprint ends", str(p.get_stance_info()["state"]) != "SPRINTING",
					"now=%s" % p.get_stance_info()["state"])
				_report()
				return true
	return false

func _place(x: float, z: float, yaw_in: float) -> void:
	var p = main.player
	Input.action_release("move_forward")
	p.global_position = Vector3(x, 0.3, z)
	p.velocity = Vector3.ZERO
	p.rotation.y = yaw_in
	p.set("yaw", yaw_in)

func _check(name: String, ok: bool, detail: String) -> void:
	results.append(ok)
	print("MOVSIM: [%s] %s (%s)" % ["PASS" if ok else "FAIL", name, detail])

func _report() -> void:
	var fails := 0
	for r in results:
		if not r:
			fails += 1
	print("MOVSIM: DONE %d/%d passed" % [results.size() - fails, results.size()])
