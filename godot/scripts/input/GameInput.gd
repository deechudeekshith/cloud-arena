class_name GameInput
extends RefCounted

## ONE gameplay input interface for PC and mobile.
## PlayerController only talks to GameInput: it never cares whether the
## signal came from keyboard/mouse or a touchscreen.
##
## Logical surface:
##   get_move() -> Vector2   x = strafe right+, y = forward+
##   pressed(action)         held state ("fire", "sprint", ...)
##   just_pressed(action)    edge latch ("jump","crouch","prone","sprint",
##                           "reload","ability","weapon_1/2/3","weapon_cycle")
##   consume_look() -> Vector2  accumulated look delta (touch drags).
##                           PC returns ZERO (mouse look uses events).
##   device_name()           "PC" / "TOUCH" (debug overlay)
##   debug_state()           Dictionary for the F4 input overlay

func get_move() -> Vector2:
	return Vector2.ZERO

func pressed(_action: String) -> bool:
	return false

func just_pressed(_action: String) -> bool:
	return false

func consume_look() -> Vector2:
	return Vector2.ZERO

func device_name() -> String:
	return "NONE"

func debug_state() -> Dictionary:
	return {"device": device_name(), "move": get_move(), "look": Vector2.ZERO,
		"fire": pressed("fire"), "jump": pressed("jump"), "crouch": pressed("crouch"),
		"prone": pressed("prone"), "sprint": pressed("sprint"),
		"reload": pressed("reload"), "weapon": "-"}

## PC implementation: thin wrapper over the InputMap actions.
class PC extends GameInput:
	func get_move() -> Vector2:
		return Vector2(Input.get_axis("move_left", "move_right"),
			Input.get_axis("move_back", "move_forward"))

	func pressed(action: String) -> bool:
		return Input.is_action_pressed(action)

	func just_pressed(action: String) -> bool:
		if not InputMap.has_action(action):
			return false
		return Input.is_action_just_pressed(action)

	func device_name() -> String:
		return "PC"

	func debug_state() -> Dictionary:
		return {"device": "PC", "move": get_move(), "look": Vector2.ZERO,
			"fire": pressed("fire"), "jump": pressed("jump"), "crouch": pressed("crouch"),
			"prone": pressed("prone"), "sprint": pressed("sprint"),
			"reload": pressed("reload"), "weapon": "-"}

## Network-fed implementation (server-side bodies for remote humans).
## The server writes each tick from validated input packets; edges latch
## until consumed, exactly like Touch.
class Net extends GameInput:
	var move := Vector2.ZERO
	var pose := Vector2.ZERO # absolute yaw, pitch from owning client
	var held := {}
	var queued := {}

	func feed(move_v: Vector2, yaw_pitch: Vector2, held_in: Dictionary, pressed_list: Array) -> void:
		move = move_v
		pose = yaw_pitch
		for k in held_in:
			held[k] = held_in[k]
		# fed from idle-time RPC dispatch: stamp the UPCOMING physics frame
		# so the edge is observed exactly once, on the next physics tick
		# (see Touch.press for the counter semantics).
		var f := Engine.get_physics_frames() + 1
		for a in pressed_list:
			queued[str(a)] = f

	func consume_pose() -> Vector2:
		return pose

	func get_move() -> Vector2:
		if move.length() > 1.0:
			return move.normalized()
		return move

	func pressed(action: String) -> bool:
		return bool(held.get(action, false))

	func just_pressed(action: String) -> bool:
		return int(queued.get(action, -999999)) == Engine.get_physics_frames()

	func device_name() -> String:
		return "NET"

	func debug_state() -> Dictionary:
		return {"device": "NET", "move": get_move(), "look": pose,
			"fire": pressed("fire"), "jump": pressed("jump"), "crouch": pressed("crouch"),
			"prone": pressed("prone"), "sprint": pressed("sprint"),
			"reload": pressed("reload"), "weapon": "-"}
## Touch implementation: state driven by the TouchUI layer. Edges are
## frame-stamped so local sim and net sender can both observe them.
class Touch extends GameInput:
	var move := Vector2.ZERO
	var look_accum := Vector2.ZERO
	var last_look := Vector2.ZERO
	var held := {}
	var queued := {}
	var deadzone := 0.15
	var weapon_name := "-"

	func set_move(v: Vector2) -> void:
		move = v

	func add_look(d: Vector2) -> void:
		look_accum += d

	func press(action: String) -> void:
		held[action] = true
		# Button presses arrive as idle-time GUI events, when
		# Engine.get_physics_frames() still reports the LAST completed
		# frame. Stamping the upcoming frame makes just_pressed() true
		# exactly once, on the next physics tick (verified by FrameProbe:
		# idle reads N-1, the following physics step reads N).
		queued[action] = Engine.get_physics_frames() + 1

	func release(action: String) -> void:
		held[action] = false

	func get_move() -> Vector2:
		var m := move
		if m.length() < deadzone:
			return Vector2.ZERO
		if m.length() > 1.0:
			m = m.normalized()
		return m

	func pressed(action: String) -> bool:
		return bool(held.get(action, false))

	func just_pressed(action: String) -> bool:
		return int(queued.get(action, -999999)) == Engine.get_physics_frames()

	func consume_look() -> Vector2:
		var d := look_accum
		look_accum = Vector2.ZERO
		last_look = d
		return d

	func device_name() -> String:
		return "TOUCH"

	func debug_state() -> Dictionary:
		return {"device": "TOUCH", "move": get_move(), "look": last_look,
			"fire": pressed("fire"), "jump": pressed("jump"), "crouch": pressed("crouch"),
			"prone": pressed("prone"), "sprint": pressed("sprint"),
			"reload": pressed("reload"), "weapon": weapon_name}
