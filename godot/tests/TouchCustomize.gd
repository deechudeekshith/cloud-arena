# Touch layout customization test: opens the CUSTOMIZE screen, simulates
# dragging the joystick + a button, commits, and verifies positions persist
# and are applied to TouchUI.
# Run: DISPLAY=:0 godot --path <project> --resolution 1280x720 --script res://tests/TouchCustomize.gd
extends SceneTree

var frames := 0
var main: Node = null
var menus: Node = null
var done := false

func _initialize() -> void:
	var ps: PackedScene = load("res://scenes/main/Main.tscn")
	main = ps.instantiate()
	root.add_child(main)

func _process(_dt: float) -> bool:
	frames += 1
	if frames == 5:
		main.settings.touch_mode = 1
		menus = main.menus
		menus.show_screen("TOUCH_CUSTOMIZE")
		return false
	if frames == 10:
		var overlay: Control = menus.touch_customize_overlay
		print("CUSTOMIZE: overlay_visible=", overlay.visible,
			" handles=", menus.touch_drag_items.size())
		# Drag joystick from its default to a new spot via direct call.
		var joy = menus.touch_drag_joy
		menus._on_drag_moved(joy, Vector2(0.25, 0.45))
		# Drag the FIRE button handle to a CLEAR spot: (0.70, 0.62) keeps
		# >=100px from JUMP/DUCK/ADS/PRONE at 1280x720 (an overlapping
		# drop would bury the button under its neighbor on later runs).
		var fire = null
		for it in menus.touch_drag_items:
			if it.action == "fire":
				fire = it
		if fire != null:
			menus._on_drag_moved(fire, Vector2(0.70, 0.62))
		menus._on_touch_customize_done()
		return false
	if frames == 15:
		var s = main.settings
		print("CUSTOMIZE: saved_joy=", s.touch_joy_pos, " saved_fire=", s.touch_button_positions.get("fire", "MISSING"))
		var ok_joy = absf(s.touch_joy_pos.x - 0.25) < 0.001
		var ok_fire = s.touch_button_positions.has("fire") and absf(s.touch_button_positions["fire"].x - 0.70) < 0.001
		var tui = main.touch_ui
		var ok_applied = absf(tui.joy_frac.x - 0.25) < 0.001
		print("CUSTOMIZE: [%s] joy persist" % ("PASS" if ok_joy else "FAIL"))
		print("CUSTOMIZE: [%s] button persist" % ("PASS" if ok_fire else "FAIL"))
		print("CUSTOMIZE: [%s] applied to TouchUI" % ("PASS" if ok_applied else "FAIL"))
		# Reload from disk to prove persistence.
		var reloaded = GameSettings.load()
		var ok_disk = absf(reloaded.touch_joy_pos.x - 0.25) < 0.001 and reloaded.touch_button_positions.has("fire")
		print("CUSTOMIZE: [%s] persisted to disk" % ("PASS" if ok_disk else "FAIL"))
		# Hygiene: restore defaults on disk so later runs (TouchSim, …)
		# always start from the known-good default layout + auto touch mode.
		main.settings.touch_mode = 0
		main.settings.touch_joy_pos = TouchUI.DEFAULT_JOY_FRAC
		main.settings.touch_button_positions.clear()
		main.settings.save()
		print("CUSTOMIZE: DONE")
		done = true
		return true
	return false
