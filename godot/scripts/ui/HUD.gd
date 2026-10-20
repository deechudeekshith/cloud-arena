class_name HUD
extends CanvasLayer

## In-match HUD: crosshair + hitmarker, health, ammo, timer, team scores,
## killfeed, respawn/countdown overlays, damage flash.
## Code-built (no .tscn fragility). Bound to the human player by GameRoot.

var player: PlayerController
var cross: Control
var hitmark: Label
var healthbar: HealthBar
var hp_num: Label
var hp_cap: Label
var vign_mat: ShaderMaterial
var ammo_label: Label
var reload_bar: ProgressBar
var timer_label: Label
var score_label: Label
var feed_box: VBoxContainer
var center_label: Label
var respawn_label: Label
var flash: ColorRect
var alive_rows := {}
var move_panel: PanelContainer
var move_label: Label
var show_move_debug := true
var join_label: Label
var hit_player: AudioStreamPlayer
var hit_stream: AudioStreamWAV

var _hit_t := 99.0
var join_t := 0.0
var _feed: Array = []

func _ready() -> void:
	layer = 10
	_build()

func bind(p: PlayerController) -> void:
	player = p
	if player:
		player.ammo_changed.connect(func(_m: int, _r: int) -> void: _refresh_ammo())

func _mk_label(text: String, size: int, color: Color = Color.WHITE) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE # never block touch look/buttons
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	l.add_theme_constant_override("shadow_offset_x", 2)
	l.add_theme_constant_override("shadow_offset_y", 2)
	return l

func _build() -> void:
	# low-HP edge vignette (fullscreen, drawn under everything else)
	var vign := ColorRect.new()
	vign.set_anchors_preset(Control.PRESET_FULL_RECT)
	vign.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vign_mat = ShaderMaterial.new()
	var vsh := Shader.new()
	vsh.code = "shader_type canvas_item;\nuniform float strength = 0.0;\nvoid fragment() {\n\tvec2 d = abs(UV - 0.5) * 2.0;\n\tfloat edge = smoothstep(0.45, 1.0, max(d.x, d.y));\n\tCOLOR = vec4(0.6, 0.03, 0.02, edge * strength);\n}"
	vign_mat.shader = vsh
	vign.material = vign_mat
	vign.color = Color(1, 1, 1, 1)
	add_child(vign)
	# crosshair
	cross = Crosshair.new()
	cross.set_anchors_preset(Control.PRESET_CENTER)
	add_child(cross)
	hitmark = _mk_label("", 28, Color(1, 0.3, 0.25))
	hitmark.set_anchors_preset(Control.PRESET_CENTER)
	hitmark.position += Vector2(-10, -44)
	add_child(hitmark)
	# top center: timer + score
	var top := VBoxContainer.new()
	top.set_anchors_preset(Control.PRESET_CENTER_TOP)
	top.position = Vector2(-160, 10)
	top.custom_minimum_size = Vector2(320, 0)
	top.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(top)
	timer_label = _mk_label("3:00", 30)
	timer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	top.add_child(timer_label)
	score_label = _mk_label("BLUE 0 — 0 RED", 20, Color(0.7, 0.85, 1))
	score_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	top.add_child(score_label)
	# killfeed
	feed_box = VBoxContainer.new()
	feed_box.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	feed_box.position = Vector2(-330, 10)
	feed_box.custom_minimum_size = Vector2(320, 0)
	feed_box.alignment = BoxContainer.ALIGNMENT_BEGIN
	add_child(feed_box)
	# bottom-left health: big number + caption + custom bar
	var bl := HBoxContainer.new()
	bl.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	bl.position = Vector2(16, -96)
	bl.add_theme_constant_override("separation", 12)
	add_child(bl)
	hp_num = _mk_label("100", 44)
	hp_num.add_theme_constant_override("outline_size", 8)
	hp_num.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	bl.add_child(hp_num)
	var bcol := VBoxContainer.new()
	bcol.add_theme_constant_override("separation", 2)
	bl.add_child(bcol)
	hp_cap = _mk_label("HEALTH", 14, Color(0.65, 0.75, 0.9))
	bcol.add_child(hp_cap)
	healthbar = HealthBar.new()
	bcol.add_child(healthbar)
	# bottom-right ammo
	var br := VBoxContainer.new()
	br.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	br.position = Vector2(-220, -110)
	br.custom_minimum_size = Vector2(200, 0)
	add_child(br)
	ammo_label = _mk_label("30 / 120", 30)
	ammo_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	br.add_child(ammo_label)
	reload_bar = ProgressBar.new()
	reload_bar.min_value = 0
	reload_bar.max_value = 1
	reload_bar.custom_minimum_size = Vector2(200, 8)
	reload_bar.show_percentage = false
	reload_bar.visible = false
	reload_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	br.add_child(reload_bar)
	# movement debug (F4 toggles; dev/test aid)
	move_panel = PanelContainer.new()
	move_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	move_panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	move_panel.position = Vector2(16, -400)
	var msb := StyleBoxFlat.new()
	msb.bg_color = Color(0, 0, 0, 0.55)
	msb.content_margin_left = 8
	msb.content_margin_right = 8
	msb.content_margin_top = 6
	msb.content_margin_bottom = 6
	move_panel.add_theme_stylebox_override("panel", msb)
	move_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(move_panel)
	move_label = _mk_label("STATE: -\nSPEED: -\nNORMAL: -\nSPRINT: -", 14, Color(0.6, 1.0, 0.6))
	move_panel.add_child(move_label)
	# center big label (countdown / announcements)
	center_label = _mk_label("", 64)
	center_label.set_anchors_preset(Control.PRESET_CENTER)
	center_label.position = Vector2(-200, -120)
	center_label.custom_minimum_size = Vector2(400, 100)
	center_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(center_label)
	respawn_label = _mk_label("", 24, Color(1, 0.6, 0.5))
	respawn_label.set_anchors_preset(Control.PRESET_CENTER)
	respawn_label.position = Vector2(-200, 40)
	respawn_label.custom_minimum_size = Vector2(400, 40)
	respawn_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(respawn_label)
	# host-side join banner
	join_label = _mk_label("", 26, Color(0.45, 0.95, 1.0))
	join_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	join_label.position = Vector2(-320, 96)
	join_label.custom_minimum_size = Vector2(640, 40)
	join_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(join_label)
	# damage flash
	flash = ColorRect.new()
	flash.set_anchors_preset(Control.PRESET_FULL_RECT)
	flash.color = Color(1, 0.1, 0.1, 0.0)
	flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(flash)
	# hit-confirm blip (procedural, pitch marks headshot/kill)
	hit_stream = Weapon.make_click_stream(1500.0, 0.06)
	hit_player = AudioStreamPlayer.new()
	hit_player.bus = "Master"
	add_child(hit_player)

func _process(dt: float) -> void:
	_hit_t += dt
	if hitmark.text != "" and _hit_t > 0.5:
		hitmark.text = ""
	if flash.color.a > 0.0:
		flash.color.a = maxf(0.0, flash.color.a - dt * 1.8)
	if join_t > 0.0:
		join_t -= dt
		if join_t <= 0.0:
			join_label.text = ""
		elif join_t < 1.0: # fade out over the last second
			join_label.modulate.a = join_t
	if player == null or player.weapon == null:
		return
	cross.set("spread", lerpf(1.0, 0.45, player.aim_factor))
	var hpm: float = player.health.hp
	var hmax: float = player.health.max_hp
	healthbar.set_hp(hpm, hmax)
	var frac := clampf(hpm / maxf(1.0, hmax), 0.0, 1.0)
	hp_num.text = "%d" % int(ceili(hpm))
	if frac < 0.32:
		# critical: red pulsing number + caption + screen-edge vignette
		var pulse := 0.6 + 0.4 * sin(Time.get_ticks_msec() / 1000.0 * 7.0)
		hp_num.add_theme_color_override("font_color", Color(1.0, 0.25 + 0.2 * pulse, 0.2))
		hp_cap.text = "⚠ CRITICAL"
		hp_cap.add_theme_color_override("font_color", Color(1.0, 0.35, 0.3))
		vign_mat.set_shader_parameter("strength", (1.0 - frac / 0.32) * (0.35 + 0.2 * pulse))
	else:
		hp_num.add_theme_color_override("font_color", Color.WHITE)
		hp_cap.text = "HEALTH"
		hp_cap.add_theme_color_override("font_color", Color(0.65, 0.75, 0.9))
		vign_mat.set_shader_parameter("strength", 0.0)
	_refresh_ammo()
	_update_move_debug()
	if get_viewport().get_camera_3d() == null:
		(player.get_node("Head/Camera3D") as Camera3D).current = true

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("move_debug"):
		show_move_debug = not show_move_debug
		if move_panel:
			move_panel.visible = show_move_debug

func _update_move_debug() -> void:
	if move_panel == null or player == null:
		return
	if not player.has_method("get_stance_info"):
		return
	var info: Dictionary = player.get_stance_info()
	var inp: Dictionary = player.input_provider.debug_state() if player.input_provider else {}
	var mv: Vector2 = inp.get("move", Vector2.ZERO)
	var lk: Vector2 = inp.get("look", Vector2.ZERO)
	var wname := "-"
	if player.weapon:
		wname = player.weapon.display_name()
		if player.input_provider is GameInput.Touch:
			(player.input_provider as GameInput.Touch).weapon_name = wname
	move_label.text = "STATE: %s\nSPEED: %0.1f\nNORMAL: %0.1f\nSPRINT: %s\n---\nIN: %s\nMOVE: %0.2f,%0.2f\nLOOK: %0.0f,%0.0f\nFIRE:%s JUMP:%s\nCRCH:%s PRONE:%s\nSPRINT:%s RLD:%s\nWPN: %s" % [
		str(info.get("state", "?")), float(info.get("speed", 0.0)),
		float(info.get("normal", 0.0)), str(info.get("sprint", "?")),
		str(inp.get("device", "?")), mv.x, mv.y, lk.x, lk.y,
		"ON" if inp.get("fire", false) else "--",
		"ON" if inp.get("jump", false) else "--",
		"ON" if inp.get("crouch", false) else "--",
		"ON" if inp.get("prone", false) else "--",
		"ON" if inp.get("sprint", false) else "--",
		"ON" if inp.get("reload", false) else "--", wname]

func _refresh_ammo() -> void:
	if player == null or player.weapon == null:
		return
	ammo_label.text = "%d / %d" % [player.weapon.mag, player.weapon.reserve]
	var rp: float = player.weapon.reload_progress()
	reload_bar.visible = rp >= 0.0
	if rp >= 0.0:
		reload_bar.value = rp
		ammo_label.text = "RELOADING"

func set_match(time_left: float, s0: int, s1: int) -> void:
	var t := maxf(0.0, time_left)
	timer_label.text = "%d:%02d" % [int(t) / 60, int(t) % 60]
	if t < 30.0:
		timer_label.add_theme_color_override("font_color", Color(1, 0.4, 0.35))
	score_label.text = "BLUE %d — %d RED" % [s0, s1]

func announce(text: String, dur := 1.2) -> void:
	center_label.text = text
	var tw := create_tween()
	tw.tween_interval(dur)
	tw.tween_callback(func() -> void: center_label.text = "")

func killfeed(victim: String, killer: String, headshot: bool, vteam: int, kteam: int) -> void:
	var l := _mk_label("", 15)
	l.text = "%s  ✕  %s%s" % [killer, victim, "  ☠" if headshot else ""]
	# tint by killer team (world kills stay white) so teams read at a glance
	if kteam == 0:
		l.add_theme_color_override("font_color", Color(0.55, 0.75, 1.0))
	elif kteam == 1:
		l.add_theme_color_override("font_color", Color(1.0, 0.55, 0.5))
	l.modulate = Color(1, 1, 1, 1)
	feed_box.add_child(l)
	_feed.append(l)
	if _feed.size() > 5:
		(_feed.pop_front() as Control).queue_free()
	var tw := l.create_tween()
	tw.tween_interval(5.0)
	tw.tween_callback(func() -> void:
		if is_instance_valid(l):
			_feed.erase(l)
			l.queue_free())

func hitmarker(headshot: bool, killed: bool) -> void:
	_hit_t = 0.0
	hitmark.text = "✕"
	hitmark.add_theme_color_override("font_color",
		Color(1, 0.2, 0.15) if killed else (Color(1, 0.6, 0.1) if headshot else Color.WHITE))
	if hit_player and hit_stream:
		hit_player.stream = hit_stream
		hit_player.pitch_scale = 1.5 if killed else (1.25 if headshot else 1.0)
		hit_player.play()

func damage_flash() -> void:
	flash.color.a = 0.45

func show_respawn(t: float) -> void:
	if t <= 0.0:
		respawn_label.text = ""
	else:
		respawn_label.text = "Respawning in %0.1f…" % t

## Host-side "someone is knocking" banner. Mirrors the desktop notification
## so the host sees it even with no notification daemon running.
func show_join_banner(text: String, seconds: float) -> void:
	join_label.text = text
	join_t = seconds

class Crosshair extends Control:
	var spread := 1.0 # 1.0 hip, ~0.45 full ADS (set by HUD each frame)
	func _ready() -> void:
		custom_minimum_size = Vector2(40, 40)
		position -= Vector2(20, 20)
		mouse_filter = Control.MOUSE_FILTER_IGNORE
	func _draw() -> void:
		var c := Vector2(20, 20)
		var col := Color(1, 1, 1, 0.9)
		draw_circle(c, 2.0, col)
		for d in [Vector2(8, 0), Vector2(-8, 0), Vector2(0, 8), Vector2(0, -8)]:
			draw_line(c + d * spread, c + d * spread * 1.8, col, 2.0)
	func _process(_dt: float) -> void:
		queue_redraw()
