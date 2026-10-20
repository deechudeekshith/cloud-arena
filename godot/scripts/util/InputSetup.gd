class_name InputSetup
extends RefCounted

## Runtime input map. Keeps project.godot minimal and avoids fragile
## .godot input serialization. Called once from GameRoot.

static var _done := false

static func ensure() -> void:
	if _done:
		return
	_done = true
	_add_key("move_forward", [KEY_W, KEY_UP])
	_add_key("move_back", [KEY_S, KEY_DOWN])
	_add_key("move_left", [KEY_A, KEY_LEFT])
	_add_key("move_right", [KEY_D, KEY_RIGHT])
	_add_key("jump", [KEY_SPACE])
	_add_key("sprint", [KEY_SHIFT])
	_add_key("crouch", [KEY_C, KEY_CTRL])
	_add_key("prone", [KEY_Z])
	_add_key("ability", [KEY_Q])
	_add_key("fire", [], [MOUSE_BUTTON_LEFT])
	_add_key("aim", [], [MOUSE_BUTTON_RIGHT])
	_add_key("reload", [KEY_R])
	_add_key("pause", [KEY_ESCAPE, KEY_P])
	_add_key("weapon_1", [KEY_1])
	_add_key("weapon_2", [KEY_2])
	_add_key("weapon_3", [KEY_3])
	_add_key("perf_toggle", [KEY_F3])
	_add_key("move_debug", [KEY_F4])
	_add_key("menu_ok", [KEY_ENTER, KEY_KP_ENTER])

static func _add_key(action: String, keys: Array, mouse: Array = []) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	for k in keys:
		var ev := InputEventKey.new()
		ev.physical_keycode = k
		if not InputMap.action_has_event(action, ev):
			InputMap.action_add_event(action, ev)
	for m in mouse:
		var ev2 := InputEventMouseButton.new()
		ev2.button_index = m
		if not InputMap.action_has_event(action, ev2):
			InputMap.action_add_event(action, ev2)
