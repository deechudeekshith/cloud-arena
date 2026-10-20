# Touch input verification: forced touch UI, synthetic multi-touch through
# the real GUI path. Stages POLL for conditions (input dispatch timing is
# independent of this script's frame rate), with wall-clock timeouts.
# Run: DISPLAY=:0 godot --path <project> --resolution 1280x720 --script res://tests/TouchSim.gd
extends SceneTree

var frames := 0
var main: Node = null
var tui = null
var prov = null
var stage := 0
var stage_t0 := 0
var results: Array = []
var look_yaw0 := 0.0
var mag0 := 0
var slot0 := 0
var tap_sent := false
var stage6_tapped := false
var sprint_setup := false
var sprint_tapped := false

func _now() -> int:
	return Time.get_ticks_msec()

func _enter(s: int) -> void:
	stage = s
	stage_t0 = _now()
	tap_sent = false

func _tout(sec: float) -> bool:
	return float(_now() - stage_t0) / 1000.0 > sec

func _initialize() -> void:
	var ps: PackedScene = load("res://scenes/main/Main.tscn")
	main = ps.instantiate()
	root.add_child(main)

func _process(_dt: float) -> bool:
	frames += 1
	if frames == 5:
		main.settings.touch_mode = 1 # force touch UI on desktop
		main.start_match()
		tui = main.touch_ui
		prov = tui.provider
		print("TOUCHSIM: touch_active=", main.touch_active(), " tui_visible=", tui.visible,
			" provider=", main.player.input_provider.device_name())
		_check("touch provider assigned", main.player.input_provider == prov, "")
		main.player.health.max_hp = 100000.0
		main.player.health.hp = 100000.0
		_enter(1)
		return false
	if frames < 6 or main.phase != 2:
		return false
	var p = main.player
	match stage:
		1: # joystick held forward through real GUI
			_hold_joy()
			var mv: Vector2 = prov.get_move()
			if mv.y > 0.4 and absf(mv.x) < 0.2:
				_check("joystick move", true, str(mv))
				look_yaw0 = p.rotation.y
				_enter(2)
			elif _tout(10.0):
				_check("joystick move", false, str(mv))
				look_yaw0 = p.rotation.y
				_enter(2)
		2: # second finger look-drag while joystick held
			_hold_joy()
			_drag_look()
			if absf(p.rotation.y - look_yaw0) > 0.05:
				_check("look while moving", true, "dyaw=%0.3f" % (p.rotation.y - look_yaw0))
				_check("move kept during look", prov.get_move().y > 0.4, str(prov.get_move()))
				mag0 = p.weapon.mag
				_touch(2, true, tui.button_center_global("fire"))
				_enter(3)
			elif _tout(10.0):
				_check("look while moving", false, "")
				_check("move kept during look", false, "")
				mag0 = p.weapon.mag
				_touch(2, true, tui.button_center_global("fire"))
				_enter(3)
		3: # move + look + fire: mag must drop
			_hold_joy()
			_drag_look()
			if p.weapon.mag < mag0:
				_check("fire held (3 fingers)", prov.pressed("fire"), "")
				_check("mag decreasing", true, "mag=%d" % p.weapon.mag)
				_release_all()
				_enter(4)
			elif _tout(10.0):
				_check("fire held (3 fingers)", false, "")
				_check("mag decreasing", false, "mag=%d" % p.weapon.mag)
				_release_all()
				_enter(4)
		4: # crouch button
			if not tap_sent:
				_tap("crouch")
				tap_sent = true
			if str(p.get_stance_info()["state"]) == "CROUCHING":
				_check("touch crouch", true, "CROUCHING")
				_enter(5)
			elif _tout(8.0):
				_check("touch crouch", false, str(p.get_stance_info()["state"]))
				_enter(5)
		5: # prone button
			if not tap_sent:
				_tap("prone")
				tap_sent = true
			var st5: String = str(p.get_stance_info()["state"])
			if st5 == "PRONE" or st5 == "CRAWLING":
				_check("touch prone", true, st5)
				_enter(6)
			elif _tout(8.0):
				_check("touch prone", false, st5)
				_enter(6)
		6: # unwind to standing: prone->crouch->stand (one tap each)
			var st6: String = str(p.get_stance_info()["state"])
			if st6 == "PRONE" or st6 == "CRAWLING":
				if not tap_sent:
					_tap("prone")
					tap_sent = true
			elif st6 == "CROUCHING":
				if not stage6_tapped:
					_tap("crouch")
					stage6_tapped = true
			elif st6 == "STANDING":
				_check("stance unwind", true, st6)
				_enter(7)
			if _tout(15.0) and stage == 6:
				_check("stance unwind", false, str(p.get_stance_info()["state"]))
				_enter(7)
		7: # jump button
			if not tap_sent:
				_tap("jump")
				tap_sent = true
			if not p.is_on_floor():
				_check("touch jump airborne", true, "")
				_enter(8)
			elif _tout(8.0):
				_check("touch jump airborne", false, "never left ground")
				_enter(8)
		8: # sprint: open field + joystick + RUN tap
			if not sprint_setup and _tout(0.5):
				p.global_position = Vector3(0, 0.3, 20)
				p.velocity = Vector3.ZERO
				p.rotation.y = -PI * 0.5
				p.set("yaw", -PI * 0.5)
				sprint_setup = true
			_hold_joy()
			if sprint_setup and not sprint_tapped and _tout(1.0):
				_tap("sprint")
				sprint_tapped = true
			if str(p.get_stance_info()["state"]) == "SPRINTING":
				_check("touch sprint burst", true, str(p.get_stance_info()))
				_release_all()
				_enter(9)
			elif _tout(10.0):
				_check("touch sprint burst", false, str(p.get_stance_info()["state"]))
				_release_all()
				_enter(9)
		9: # reload button
			if not tap_sent:
				_tap("reload")
				tap_sent = true
			var rp: float = p.weapon.reload_progress()
			if rp >= 0.0:
				_check("touch reload", true, "rp=%0.2f" % rp)
				slot0 = p.weapon_slot
				_enter(10)
			elif _tout(8.0):
				_check("touch reload", false, "rp=%0.2f mag=%d" % [rp, p.weapon.mag])
				slot0 = p.weapon_slot
				_enter(10)
		10: # weapon cycle button
			if not tap_sent:
				_tap("weapon_cycle")
				tap_sent = true
			if p.weapon_slot != slot0:
				_check("touch weapon switch", true, "%d -> %d" % [slot0, p.weapon_slot])
				_end()
				return true
			elif _tout(8.0):
				_check("touch weapon switch", false, "%d -> %d" % [slot0, p.weapon_slot])
				_end()
				return true
	return false

# ---- helpers ----
func _hold_joy() -> void:
	# finger 0 kept down; drag re-sent so delivery timing never matters
	_touch_down(0, tui.joystick_center_global())
	_drag(0, tui.joystick_center_global(), tui.joystick_center_global() + Vector2(0, -60))

func _drag_look() -> void:
	var lp: Vector2 = tui.look_point_global()
	_touch_down(1, lp)
	_drag(1, lp, lp + Vector2(40, 0))

func _release_all() -> void:
	_touch(0, false, tui.joystick_center_global())
	_touch(1, false, tui.look_point_global())
	_touch(2, false, tui.button_center_global("fire"))

func _touch_down(idx: int, pos: Vector2) -> void:
	var ev := InputEventScreenTouch.new()
	ev.index = idx
	ev.pressed = true
	ev.position = pos
	Input.parse_input_event(ev)

func _touch(idx: int, pressed: bool, pos: Vector2) -> void:
	var ev := InputEventScreenTouch.new()
	ev.index = idx
	ev.pressed = pressed
	ev.position = pos
	Input.parse_input_event(ev)

func _drag(idx: int, from: Vector2, to: Vector2) -> void:
	var ev := InputEventScreenDrag.new()
	ev.index = idx
	ev.position = to
	ev.relative = to - from
	Input.parse_input_event(ev)

func _tap(action: String) -> void:
	_touch(3, true, tui.button_center_global(action))
	_touch(3, false, tui.button_center_global(action))

func _check(name: String, ok: bool, detail: String) -> void:
	results.append(ok)
	print("TOUCHSIM: [%s] %s %s" % ["PASS" if ok else "FAIL", name, ("(" + detail + ")") if detail != "" else ""])

func _end() -> void:
	_release_all()
	var fails := 0
	for r in results:
		if not r:
			fails += 1
	print("TOUCHSIM: DONE %d/%d passed" % [results.size() - fails, results.size()])
