# Stairs/slope verification: walk up the movement-course stairs (x 8..11,
# z=52) and the plaza ramp, headless.
# Run: godot --headless --path <project> --script res://tests/StairSim.gd
extends SceneTree

var frames := 0
var main: Node = null
var stage := 0
var stage_frame := 0
var results: Array = []

func _initialize() -> void:
	var ps: PackedScene = load("res://scenes/main/Main.tscn")
	main = ps.instantiate()
	root.add_child(main)

func _process(_dt: float) -> bool:
	frames += 1
	if frames == 5:
		main.start_match()
		main.player.health.max_hp = 100000.0
		main.player.health.hp = 100000.0
		_place(Vector3(6.0, 0.3, 52.0), -PI * 0.5)
		stage = 1
		stage_frame = frames
		print("STAIRSIM: stage 1 climb stairs facing +X")
		return false
	if frames < 6 or main.phase != 2:
		return false
	var p = main.player
	match stage:
		1: # walk forward up the stairs: must reach deck height
			Input.action_press("move_forward")
			if p.global_position.y > 0.9 and p.global_position.x > 9.5:
				Input.action_release("move_forward")
				_check("stairs ascend", true,
					"pos=%s" % str(p.global_position))
				_place(Vector3(10.6, 1.3, 52.0), PI * 0.5)
				stage = 2
				stage_frame = frames
				print("STAIRSIM: stage 2 walk back down")
			elif frames - stage_frame > 900:
				Input.action_release("move_forward")
				_check("stairs ascend", false,
					"pos=%s" % str(p.global_position))
				_place(Vector3(0.0, 0.3, 14.5), 0.0)
				stage = 3
				stage_frame = frames
				print("STAIRSIM: stage 3 plaza ramp")
		2: # walk back down: must reach ground without sticking
			if frames - stage_frame > 30:
				Input.action_press("move_forward")
			if p.global_position.x < 6.5 and p.global_position.y < 0.4:
				Input.action_release("move_forward")
				_check("stairs descend", true,
					"pos=%s" % str(p.global_position))
				_place(Vector3(0.0, 0.3, 14.5), 0.0)
				stage = 3
				stage_frame = frames
				print("STAIRSIM: stage 3 plaza ramp")
			elif frames - stage_frame > 900:
				Input.action_release("move_forward")
				_check("stairs descend", false,
					"pos=%s" % str(p.global_position))
				_place(Vector3(0.0, 0.3, 14.5), 0.0)
				stage = 3
				stage_frame = frames
				print("STAIRSIM: stage 3 plaza ramp")
		3: # plaza ramp: start just south of the ramp foot (z=14.5) and
			# walk -Z up onto the 1m plaza (barrier at z~18 is legit cover,
			# tested implicitly by being walk-around-able, not here)
			if frames - stage_frame > 30:
				Input.action_press("move_forward")
			if p.global_position.y > 0.9:
				Input.action_release("move_forward")
				_check("plaza ramp ascend", true,
					"pos=%s" % str(p.global_position))
				_report()
				return true
			elif frames - stage_frame > 900:
				Input.action_release("move_forward")
				_check("plaza ramp ascend", false,
					"pos=%s" % str(p.global_position))
				_report()
				return true
	return false

func _place(pos: Vector3, yaw_in: float) -> void:
	var p = main.player
	Input.action_release("move_forward")
	p.global_position = pos
	p.velocity = Vector3.ZERO
	p.rotation.y = yaw_in
	p.set("yaw", yaw_in)

func _check(name: String, ok: bool, detail: String) -> void:
	results.append(ok)
	print("STAIRSIM: [%s] %s (%s)" % ["PASS" if ok else "FAIL", name, detail])

func _report() -> void:
	var fails := 0
	for r in results:
		if not r:
			fails += 1
	print("STAIRSIM: DONE %d/%d passed" % [results.size() - fails, results.size()])
