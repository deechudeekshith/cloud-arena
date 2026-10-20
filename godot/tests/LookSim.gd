# Look-direction verification: drag up must look up, drag down must look
# down, drag right must yaw right; PC mouse mapping matches; invert-Y
# setting flips pitch; sensitivity setting scales. Also checks the mobile
# pause button toggles pause.
# Run: DISPLAY=:0 godot --path <project> --resolution 1280x720 --script res://tests/LookSim.gd
extends SceneTree

var frames := 0
var main: Node = null
var results: Array = []
var started := false
var done := false

func _initialize() -> void:
	var ps: PackedScene = load("res://scenes/main/Main.tscn")
	main = ps.instantiate()
	root.add_child(main)

func _process(_dt: float) -> bool:
	frames += 1
	if frames == 5:
		main.settings.touch_mode = 1
		main.settings.touch_look_sens = 1.0
		main.settings.invert_y = false
		main.settings.sens = 0.0024
		main.start_match()
		# invincible: stray bot fire must not kill/reset pitch mid-check
		main.player.health.max_hp = 100000.0
		main.player.health.hp = 100000.0
		return false
	if frames < 6 or main.phase != 2:
		return false
	if not started:
		started = true
		_run_checks()
	if done:
		return true
	return false

func _push(d: Vector2) -> void:
	# through the real look-area mapping (pixel drag -> provider -> player)
	main.touch_ui._look._push(d)

func _mouse(rx: float, ry: float) -> void:
	var mm := InputEventMouseMotion.new()
	mm.relative = Vector2(rx, ry)
	Input.parse_input_event(mm)

func _settle() -> void:
	# let exactly one physics tick consume the pushed look delta
	await physics_frame
	await physics_frame

func _run_checks() -> void:
	var p = main.player
	p.yaw = 0.0
	p.pitch = 0.0
	# 1. drag UP (finger bottom->top, d.y<0) must look UP (pitch+)
	_push(Vector2(0, -120))
	await _settle()
	_check("drag up looks up", p.pitch > 0.05, "pitch=%0.3f" % p.pitch)
	# 2. drag DOWN must look DOWN
	_push(Vector2(0, 120))
	await _settle()
	_check("drag down looks down", p.pitch < 0.05, "pitch=%0.3f" % p.pitch)
	# 3. drag RIGHT must yaw right (yaw decreases per rotation convention)
	var y0: float = p.yaw
	_push(Vector2(120, 0))
	await _settle()
	_check("drag right yaws right", p.yaw < y0 - 0.05, "dyaw=%0.3f" % (p.yaw - y0))
	# 4-5. PC mouse through the REAL event path (relative -> _apply_look).
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	p.pitch = 0.0
	_mouse(0.0, 60.0) # mouse moved DOWN on the pad
	await process_frame
	await process_frame
	_check("mouse down looks down", p.pitch < -0.01, "pitch=%0.3f" % p.pitch)
	_mouse(0.0, -120.0) # mouse moved UP twice as far -> net UP
	await process_frame
	await process_frame
	_check("mouse up looks up", p.pitch > 0.01, "pitch=%0.3f" % p.pitch)
	# 5. invert-Y flips pitch response (via Settings + live sync, as a user would)
	main.settings.invert_y = true
	await process_frame
	await process_frame
	var pi: float = p.pitch
	_mouse(0.0, 60.0)
	await process_frame
	await process_frame
	_check("invert-Y flips", p.pitch > pi, "pitch=%0.3f" % p.pitch)
	main.settings.invert_y = false
	await process_frame
	await process_frame
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# 6. sensitivity scales look response
	p.pitch = 0.0
	p.look_sens = 0.0024
	p._apply_look(Vector2(0.0, 10.0))
	var base_d: float = p.pitch
	p.pitch = 0.0
	p.look_sens = 0.0048
	p._apply_look(Vector2(0.0, 10.0))
	_check("sens scales", absf(p.pitch - 2.0 * base_d) < 0.0001, "x2=%0.4f" % p.pitch)
	p.look_sens = 0.0024
	# 7. mobile pause button toggles pause
	var was: bool = main.paused
	main.touch_ui.pause_btn.pressed.emit()
	_check("pause button pauses", main.paused != was, "paused=%s" % str(main.paused))
	main.touch_ui.pause_btn.pressed.emit()
	_check("pause button resumes", main.paused == was, "paused=%s" % str(main.paused))
	_report()

func _check(name: String, ok: bool, detail: String) -> void:
	results.append(ok)
	print("LOOKSIM: [%s] %s (%s)" % ["PASS" if ok else "FAIL", name, detail])

func _report() -> void:
	var fails := 0
	for r in results:
		if not r:
			fails += 1
	print("LOOKSIM: DONE %d/%d passed" % [results.size() - fails, results.size()])
	done = true
