class_name GameSettings
extends RefCounted

## Persisted settings (user://settings.cfg): sensitivity, quality, fps
## limit, fullscreen, invert-Y, avatar, skin. Applied without restart.

const PATH := "user://settings.cfg"

var sens := 0.0024
var invert_y := false
var quality := 1 # 0 low, 1 med, 2 high
var fps_limit := 0 # 0 uncapped, else 30/60/120
var fullscreen := false
var master_vol := 1.0 # 0..1 Master bus
var muted := false
var avatar_id := 0
var skin_id := 0
var player_name := "Player"
# touch controls: 0 = auto (touchscreen only), 1 = force on, 2 = force off
var touch_mode := 0
var touch_look_sens := 1.0
var touch_opacity := 0.85
var touch_scale := 1.0
var touch_joy_pos := Vector2(0.13, 0.62)
var touch_button_positions := {}
# host PC: desktop notification + beep when someone asks to join the room
var join_alerts := true
# scope/ADS: true = tap once to stay scoped, tap again to leave (mobile
# default); false = hold the aim button to stay scoped (classic PC feel).
var ads_toggle := true
# gentle aim assist: while scoped or firing, ease the view toward the
# nearest enemy inside a narrow cone. Never moves on its own otherwise.
var auto_aim := true
# host approval: when true a joining player is held pending until the host
# accepts from the dashboard (or the auto-approve window lapses).
var approve_joins := true

static func load() -> GameSettings:
	var s := GameSettings.new()
	var cf := ConfigFile.new()
	if cf.load(PATH) != OK:
		return s
	s.sens = float(cf.get_value("game", "sens", s.sens))
	s.invert_y = bool(cf.get_value("game", "invert_y", false))
	s.quality = int(cf.get_value("game", "quality", 1))
	s.fps_limit = int(cf.get_value("game", "fps_limit", 0))
	s.fullscreen = bool(cf.get_value("game", "fullscreen", false))
	s.master_vol = clampf(float(cf.get_value("game", "master_vol", 1.0)), 0.0, 1.0)
	s.muted = bool(cf.get_value("game", "muted", false))
	s.avatar_id = int(cf.get_value("game", "avatar_id", 0))
	s.skin_id = int(cf.get_value("game", "skin_id", 0))
	s.player_name = str(cf.get_value("game", "player_name", "Player"))
	s.touch_mode = int(cf.get_value("game", "touch_mode", 0))
	s.touch_look_sens = float(cf.get_value("game", "touch_look_sens", 1.0))
	s.touch_opacity = float(cf.get_value("game", "touch_opacity", 0.85))
	s.touch_scale = float(cf.get_value("game", "touch_scale", 1.0))
	s.join_alerts = bool(cf.get_value("game", "join_alerts", true))
	s.ads_toggle = bool(cf.get_value("game", "ads_toggle", true))
	s.auto_aim = bool(cf.get_value("game", "auto_aim", true))
	s.approve_joins = bool(cf.get_value("game", "approve_joins", true))
	var joy_x = float(cf.get_value("game", "touch_joy_x", 0.13))
	var joy_y = float(cf.get_value("game", "touch_joy_y", 0.62))
	s.touch_joy_pos = Vector2(joy_x, joy_y)
	var btn_count = int(cf.get_value("game", "touch_btn_count", 0))
	for i in range(btn_count):
		var action = str(cf.get_value("game", "touch_btn_%d_action" % i, ""))
		var fx = float(cf.get_value("game", "touch_btn_%d_x" % i, 0.0))
		var fy = float(cf.get_value("game", "touch_btn_%d_y" % i, 0.0))
		if action != "":
			s.touch_button_positions[action] = Vector2(fx, fy)
	return s

func save() -> void:
	var cf := ConfigFile.new()
	cf.set_value("game", "sens", sens)
	cf.set_value("game", "invert_y", invert_y)
	cf.set_value("game", "quality", quality)
	cf.set_value("game", "fps_limit", fps_limit)
	cf.set_value("game", "fullscreen", fullscreen)
	cf.set_value("game", "master_vol", master_vol)
	cf.set_value("game", "muted", muted)
	cf.set_value("game", "avatar_id", avatar_id)
	cf.set_value("game", "skin_id", skin_id)
	cf.set_value("game", "player_name", player_name)
	cf.set_value("game", "touch_mode", touch_mode)
	cf.set_value("game", "touch_look_sens", touch_look_sens)
	cf.set_value("game", "touch_opacity", touch_opacity)
	cf.set_value("game", "touch_scale", touch_scale)
	cf.set_value("game", "join_alerts", join_alerts)
	cf.set_value("game", "ads_toggle", ads_toggle)
	cf.set_value("game", "auto_aim", auto_aim)
	cf.set_value("game", "approve_joins", approve_joins)
	cf.set_value("game", "touch_joy_x", touch_joy_pos.x)
	cf.set_value("game", "touch_joy_y", touch_joy_pos.y)
	cf.set_value("game", "touch_btn_count", touch_button_positions.size())
	var i = 0
	for action in touch_button_positions:
		var pos: Vector2 = touch_button_positions[action]
		cf.set_value("game", "touch_btn_%d_action" % i, action)
		cf.set_value("game", "touch_btn_%d_x" % i, pos.x)
		cf.set_value("game", "touch_btn_%d_y" % i, pos.y)
		i += 1
	cf.save(PATH)

func apply(root: Window) -> void:
	Engine.max_fps = fps_limit
	if fullscreen:
		root.mode = Window.MODE_FULLSCREEN
	else:
		root.mode = Window.MODE_WINDOWED
	var bus := AudioServer.get_bus_index("Master")
	if bus >= 0:
		AudioServer.set_bus_mute(bus, muted)
		AudioServer.set_bus_volume_db(bus, linear_to_db(maxf(0.001, master_vol)))
