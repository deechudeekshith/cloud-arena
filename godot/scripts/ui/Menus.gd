class_name Menus
extends CanvasLayer

## All menus: MAIN / AVATAR / CONTROLS / SETTINGS / PAUSE / RESULTS.
## Code-built UI + live 3D avatar preview (SubViewport turntable, cheap).
## Emits intents; GameRoot owns match flow + settings persistence.

signal play_pressed
signal rematch_pressed
signal quit_to_menu
signal resume_pressed
signal quit_game
signal avatar_preview(id: int)
signal create_room_pressed
signal join_code_submitted(code: String)
signal join_manual_pressed
signal leave_room_pressed
signal ready_toggled
signal room_start_pressed
signal copy_code_pressed
signal join_screen_opened
signal results_pressed
signal details_pressed
signal touch_customize_closed

var settings: GameSettings
var bg: ColorRect
var cards := {}
var current := ""
# avatar preview
var preview_view: SubViewport
var preview_model: Node3D
var preview_id := 0
var _spin := 0.0
# settings widgets
var sens_slider: HSlider
var sens_val: Label
var quality_opt: OptionButton
var fps_opt: OptionButton
var touch_opt: OptionButton
var touch_sens_slider: HSlider
var touch_sens_val: Label
var touch_op_slider: HSlider
var touch_op_val: Label
var touch_scale_slider: HSlider
var touch_scale_val: Label
var full_check: CheckBox
var invert_check: CheckBox
# gameplay / multiplayer checkboxes
var scope_check: CheckBox
var autoaim_check: CheckBox
var approve_check: CheckBox
var alert_check: CheckBox
var vol_slider: HSlider
var vol_val: Label
var mute_check: CheckBox
# touch customize widgets
var touch_customize_overlay: Control
var touch_drag_items: Array[Control] = []
var touch_drag_joy: Control
var touch_drag_done: Button
# room / lobby widgets
var room_code_label: Label
var room_count_label: Label
var room_rows: VBoxContainer
var room_mode_opt: OptionButton
var room_bot_opt: OptionButton
var room_start_btn: Button
var room_ready_btn: Button
var room_msg: Label
var room_net_label: Label # live codec/byte savings in the lobby
# server monitor (this PC is the server): every room's details, refreshed
var rooms_list: VBoxContainer
var rooms_provider: Callable # -> Array[Dictionary] (set by GameRoot)
var netstats_provider: Callable # -> String lobby codec line (set by GameRoot)
var _rooms_acc := 0.0
var join_edit: LineEdit
var join_error: Label
var found_rows: VBoxContainer
var join_ip_edit: LineEdit
var avatar_btns: Array[Button] = []
# Back-navigation history: show_screen() pushes the previous overlay so
# Back buttons and Esc always return to the screen you came from (never
# a hardcoded MAIN). Cleared whenever gameplay takes over (hide_all) and
# never used for terminal/explicit flows (ROOM lobby, RESULTS).
var _nav: Array = []
# requested card widths, refit to small viewports (see _fit_width)
var card_widths := {}
# results
var results_title: Label
var results_rows: VBoxContainer

func _ready() -> void:
	layer = 50
	bg = ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.03, 0.05, 0.09, 0.92)
	add_child(bg)
	_build_main()
	_build_room()
	_build_join()
	_build_avatar()
	_build_controls()
	_build_settings()
	_build_pause()
	_build_results()
	_build_touch_customize()
	_build_rooms()
	show_screen("MAIN")
	get_viewport().size_changed.connect(_refit_cards)

## Small-screen support: never request a card wider than 94% of the
## viewport (floors at 280px so content stays usable on phones).
func _fit_width(w: float) -> float:
	var vw := 1280.0
	if is_instance_valid(get_viewport()):
		vw = maxf(320.0, get_viewport().get_visible_rect().size.x)
	return minf(w, maxf(280.0, vw * 0.94))

func _refit_cards() -> void:
	for k in cards:
		var center := cards[k] as Control
		if center == null:
			continue
		var panel := center.get_node_or_null("Panel") as Control
		if panel and card_widths.has(k):
			panel.custom_minimum_size = Vector2(_fit_width(float(card_widths[k])), 0)

func _card(name: String, title: String, w := 520.0) -> VBoxContainer:
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.name = "Card_" + name
	center.visible = false
	add_child(center)
	card_widths[name] = w
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(_fit_width(w), 0)
	panel.name = "Panel"
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.12, 0.2, 0.97)
	sb.border_color = Color(0.3, 0.7, 1.0)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 28
	sb.content_margin_right = 28
	sb.content_margin_top = 24
	sb.content_margin_bottom = 24
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	panel.add_child(vb)
	var t := _label(title, 34, Color(0.55, 0.85, 1.0))
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(t)
	cards[name] = center
	return vb

func _label(text: String, size: int, c: Color = Color(0.9, 0.93, 1.0)) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", c)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l

func _btn(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 44)
	b.add_theme_font_size_override("font_size", 20)
	return b

func show_screen(screen_name: String, remember := true) -> void:
	_show_touch_customize_hook(screen_name)
	if screen_name == "":
		_nav.clear()
	elif remember and current != "" and screen_name != current:
		_nav.push_back(current)
	current = screen_name
	bg.visible = screen_name != ""
	for k in cards:
		(cards[k] as Control).visible = (k == screen_name)
	if screen_name == "JOIN":
		join_error_message("")
		join_screen_opened.emit()

## Back navigation: return to the screen we came from. Safe no-op when
## the stack is empty (e.g. terminal RESULTS, in-match PAUSE without a
## settings detour, or after gameplay cleared history).
func go_back() -> void:
	if _nav.is_empty():
		return
	var prev := str(_nav.pop_back())
	show_screen(prev, false)

func hide_all() -> void:
	show_screen("")

func is_open() -> bool:
	return current != "" and current != "PAUSE_HIDDEN"

# ---------- MAIN ----------
func _build_main() -> void:
	var vb := _card("MAIN", "CLOUD ARENA", 480.0)
	var sub := _label("Lightweight 3D FPS arena  •  4v4 offline  •  3:00 match", 15, Color(0.6, 0.7, 0.85))
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(sub)
	var play := _btn("▶  PLAY (offline)")
	play.pressed.connect(func() -> void: play_pressed.emit())
	vb.add_child(play)
	var cr := _btn("Create Room")
	cr.pressed.connect(func() -> void: create_room_pressed.emit())
	vb.add_child(cr)
	var jr := _btn("Join Room")
	jr.pressed.connect(func() -> void: show_screen("JOIN"))
	vb.add_child(jr)
	var srv := _btn("🖥  Server Rooms")
	srv.pressed.connect(func() -> void:
		refresh_rooms()
		show_screen("ROOMS"))
	vb.add_child(srv)
	var rs := _btn("Results")
	rs.pressed.connect(func() -> void: results_pressed.emit())
	vb.add_child(rs)
	var av := _btn("Avatar")
	av.pressed.connect(func() -> void: show_screen("AVATAR"))
	vb.add_child(av)
	var ct := _btn("Controls")
	ct.pressed.connect(func() -> void: show_screen("CONTROLS"))
	vb.add_child(ct)
	var st := _btn("Settings")
	st.pressed.connect(func() -> void: show_screen("SETTINGS"))
	vb.add_child(st)
	var q := _btn("Quit")
	q.pressed.connect(func() -> void: quit_game.emit())
	vb.add_child(q)
	var foot := _label("WASD move • Mouse look • LMB fire • R reload • Shift+W sprint • C crouch • Z prone • Q ability • Esc pause", 13, Color(0.55, 0.6, 0.7))
	foot.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(foot)

# ---------- ROOM (lobby) ----------
func _build_room() -> void:
	var vb := _card("ROOM", "ROOM LOBBY", 560.0)
	room_code_label = _label("ROOM CODE\n------", 40, Color(0.55, 0.9, 1.0))
	room_code_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(room_code_label)
	var h := HBoxContainer.new()
	h.alignment = BoxContainer.ALIGNMENT_CENTER
	h.add_theme_constant_override("separation", 10)
	vb.add_child(h)
	var copy := _btn("Copy Code")
	copy.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	copy.pressed.connect(func() -> void: copy_code_pressed.emit())
	h.add_child(copy)
	room_count_label = _label("Players: 0 / 8", 18)
	room_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(room_count_label)
	room_rows = VBoxContainer.new()
	room_rows.add_theme_constant_override("separation", 4)
	vb.add_child(room_rows)
	var mr := HBoxContainer.new()
	mr.add_theme_constant_override("separation", 8)
	vb.add_child(mr)
	var mode_lab := _label("Mode", 17)
	mode_lab.custom_minimum_size = Vector2(64, 0)
	mr.add_child(mode_lab)
	room_mode_opt = OptionButton.new()
	room_mode_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	room_mode_opt.add_item("NORMAL", 0)
	room_mode_opt.add_item("OPTIMIZED", 1)
	room_mode_opt.select(1) # optimization applied by default
	mr.add_child(room_mode_opt)
	var bot_lab := _label("Bots", 17)
	bot_lab.custom_minimum_size = Vector2(52, 0)
	mr.add_child(bot_lab)
	room_bot_opt = OptionButton.new()
	room_bot_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for i in 8:
		room_bot_opt.add_item(str(i), i)
	mr.add_child(room_bot_opt)
	room_msg = _label("", 15, Color(1.0, 0.6, 0.4))
	room_msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(room_msg)
	room_net_label = _label("", 14, Color(0.55, 0.9, 0.7))
	room_net_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(room_net_label)
	var b := HBoxContainer.new()
	b.add_theme_constant_override("separation", 10)
	vb.add_child(b)
	room_ready_btn = _btn("Ready")
	room_ready_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	room_ready_btn.pressed.connect(func() -> void: ready_toggled.emit())
	b.add_child(room_ready_btn)
	room_start_btn = _btn("START MATCH")
	room_start_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	room_start_btn.pressed.connect(func() -> void: room_start_pressed.emit())
	b.add_child(room_start_btn)
	var lv := _btn("Leave Room")
	lv.pressed.connect(func() -> void: leave_room_pressed.emit())
	vb.add_child(lv)

func show_lobby(room: Dictionary, self_pid: String, is_host: bool) -> void:
	room_code_label.text = "ROOM CODE\n%s" % str(room.get("code", "------"))
	var players: Array = room.get("players", [])
	room_count_label.text = "Players: %d / %d   •   %s" % [
		players.size(), int(room.get("max_players", 8)), str(room.get("mode", "NORMAL"))]
	for c in room_rows.get_children():
		c.queue_free()
	for pl in players:
		var d: Dictionary = pl
		var tags := []
		tags.append("BLUE" if int(d.get("team", 0)) == 0 else "RED")
		if bool(d.get("is_host", false)):
			tags.append("HOST")
		if bool(d.get("is_bot", false)):
			tags.append("BOT")
		elif bool(d.get("ready", false)):
			tags.append("READY")
		else:
			tags.append("not ready")
		var l := _label("%s   [%s]" % [str(d.get("name", "?")), "  ".join(tags)], 16)
		if str(d.get("pid", "")) == self_pid:
			l.add_theme_color_override("font_color", Color(0.6, 1.0, 0.6))
		room_rows.add_child(l)
	room_mode_opt.visible = is_host
	room_mode_opt.select(0 if str(room.get("mode", "NORMAL")) == "NORMAL" else 1)
	room_bot_opt.visible = is_host
	room_start_btn.visible = is_host
	room_ready_btn.visible = not is_host
	room_msg.text = ""
	_update_netstats()
	# no history: the lobby is left via Leave Room / match start, never Back
	show_screen("ROOM", false)

func lobby_message(msg: String) -> void:
	if room_msg:
		room_msg.text = msg

# ---------- SERVER ROOMS (this PC is the server) ----------
func _build_rooms() -> void:
	var vb := _card("ROOMS", "🖥  SERVER ROOMS", 640.0)
	var sub := _label("Every room hosted by this PC — live.", 15, Color(0.6, 0.7, 0.85))
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(sub)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(560, 420)
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vb.add_child(scroll)
	rooms_list = VBoxContainer.new()
	rooms_list.add_theme_constant_override("separation", 8)
	rooms_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(rooms_list)
	var back := _btn("Back")
	back.pressed.connect(func() -> void: go_back())
	vb.add_child(back)

## Rebuild the server-room list. Pulls from rooms_provider (GameRoot);
## safe no-op until the provider is bound.
func refresh_rooms() -> void:
	if rooms_list == null or not rooms_provider.is_valid():
		return
	for c in rooms_list.get_children():
		c.queue_free()
	var rooms: Array = rooms_provider.call()
	if rooms.is_empty():
		rooms_list.add_child(_label("No rooms on this PC yet — Create Room to host one.", 16))
		return
	for r in rooms:
		var d: Dictionary = r
		var mine := "  ★ YOURS" if bool(d.get("is_mine", false)) else ""
		var head := _label("ROOM %s   [%s]   %s%s" % [
			str(d.get("code", "?")), str(d.get("state", "?")),
			str(d.get("mode", "?")), mine], 19,
			Color(0.6, 1.0, 0.6) if bool(d.get("is_mine", false)) else Color(0.55, 0.85, 1.0))
		rooms_list.add_child(head)
		var players: Array = d.get("players", [])
		var names: Array = []
		for pl in players:
			var p: Dictionary = pl
			var tags := []
			tags.append("BLUE" if int(p.get("team", 0)) == 0 else "RED")
			if bool(p.get("is_host", false)):
				tags.append("HOST")
			if bool(p.get("is_bot", false)):
				tags.append("BOT")
			elif bool(p.get("ready", false)):
				tags.append("READY")
			else:
				tags.append("not ready")
			tags.append(str(p.get("conn", "?")))
			names.append("• %s  [%s]" % [str(p.get("name", "?")), "  ".join(tags)])
		rooms_list.add_child(_label("Players %d/%d   •   seed %s   •   created %s" % [
			players.size(), int(d.get("max_players", 8)),
			str(d.get("map_seed", "?")), str(d.get("created_at", "?"))], 15))
		for n in names:
			rooms_list.add_child(_label("      " + n, 14, Color(0.75, 0.82, 0.92)))
		var live := str(d.get("live", ""))
		if live != "":
			rooms_list.add_child(_label("      ⚡ " + live, 14, Color(0.55, 0.9, 0.7)))
		var sep := HSeparator.new()
		rooms_list.add_child(sep)

# ---------- JOIN ----------
func _build_join() -> void:
	var vb := _card("JOIN", "JOIN ROOM", 480.0)
	vb.add_child(_label("ENTER ROOM CODE:", 16))
	join_edit = LineEdit.new()
	join_edit.max_length = 6
	join_edit.placeholder_text = "123456"
	join_edit.add_theme_font_size_override("font_size", 32)
	join_edit.alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(join_edit)
	var go := _btn("JOIN")
	go.pressed.connect(func() -> void: join_code_submitted.emit(join_edit.text.strip_edges()))
	vb.add_child(go)
	join_error = _label("", 15, Color(1.0, 0.45, 0.4))
	join_error.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(join_error)
	vb.add_child(_label("LAN rooms found:", 15, Color(0.6, 0.7, 0.85)))
	found_rows = VBoxContainer.new()
	vb.add_child(found_rows)
	vb.add_child(_label("Server address (host:port or ws://host:port):", 14, Color(0.6, 0.7, 0.85)))
	join_ip_edit = LineEdit.new()
	join_ip_edit.placeholder_text = "127.0.0.1:7777"
	var prefill := _default_server_addr()
	if prefill != "":
		join_ip_edit.text = prefill
	vb.add_child(join_ip_edit)
	var go2 := _btn("JOIN VIA ADDRESS")
	go2.pressed.connect(func() -> void: join_manual_pressed.emit())
	vb.add_child(go2)
	var back := _btn("Back")
	back.pressed.connect(func() -> void: go_back())
	vb.add_child(back)

func join_error_message(msg: String) -> void:
	if join_error:
		join_error.text = msg

## Best-effort default server address. In the web build the page was served
## by the same PC that hosts the room, so prefill "<host>:7777". On native
## there is no known server, so leave the field blank.
func _default_server_addr() -> String:
	if not OS.has_feature("web"):
		return ""
	if not Engine.has_singleton("JavaScriptBridge"):
		return ""
	var jb: Object = Engine.get_singleton("JavaScriptBridge")
	var host := str(jb.call("eval", "String((window.location&&window.location.hostname)||'')", true))
	if host == "" or host == "null" or host == "<null>":
		return ""
	return host + ":7777"

func refresh_found(found: Dictionary) -> void:
	if found_rows == null:
		return
	for c in found_rows.get_children():
		c.queue_free()
	if found.is_empty():
		found_rows.add_child(_label("No LAN rooms yet — host must be on the same network.", 14))
		return
	for code in found:
		var info: Dictionary = found[code]
		var b := _btn("%s   (%s  %d/%d)" % [code, str(info.get("host", "?")),
			int(info.get("players", 0)), int(info.get("max", 8))])
		var cc: String = code
		b.pressed.connect(func() -> void:
			join_edit.text = cc
			join_code_submitted.emit(cc))
		found_rows.add_child(b)

# ---------- AVATAR ----------
func _build_avatar() -> void:
	var vb := _card("AVATAR", "CHOOSE AVATAR", 640.0)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 16)
	vb.add_child(h)
	# 3D preview
	var svc := SubViewportContainer.new()
	svc.stretch = true
	svc.custom_minimum_size = Vector2(240, 300)
	h.add_child(svc)
	preview_view = SubViewport.new()
	preview_view.size = Vector2i(240, 300)
	preview_view.own_world_3d = true
	preview_view.transparent_bg = true
	preview_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	svc.add_child(preview_view)
	var cam := Camera3D.new()
	cam.look_at_from_position(Vector3(0, 1.4, 3.2), Vector3(0, 1.0, 0))
	preview_view.add_child(cam)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-40, -30, 0)
	preview_view.add_child(light)
	preview_view.add_child(WorldEnvironment.new())
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(list)
	for i in AvatarDB.count():
		var p: Dictionary = AvatarDB.get_preset(i)
		var b := _btn("%d. %s" % [i + 1, str(p["name"])])
		b.toggle_mode = true
		var idx := i
		b.pressed.connect(func() -> void: _pick_avatar(idx))
		list.add_child(b)
		avatar_btns.append(b)
		var desc := _label(" accessory: %s" % str(p["accessory"]), 13, Color(0.6, 0.7, 0.8))
		list.add_child(desc)
	var back := _btn("Back")
	back.pressed.connect(func() -> void: go_back())
	vb.add_child(back)
	_pick_avatar(0)

func _pick_avatar(idx: int) -> void:
	preview_id = idx
	for i in avatar_btns.size():
		avatar_btns[i].button_pressed = (i == idx)
	if preview_model and is_instance_valid(preview_model):
		preview_model.queue_free()
	var built: Dictionary = HumanoidBuilder.build(AvatarDB.get_preset(idx), 0)
	preview_model = built["root"]
	preview_view.add_child(preview_model)
	preview_model.position = Vector3(0, -0.1, 0)
	avatar_preview.emit(idx)

func _process(dt: float) -> void:
	if preview_model and is_instance_valid(preview_model) and (cards["AVATAR"] as Control).visible:
		_spin += dt * 0.8
		preview_model.rotation.y = _spin
	# server monitor + lobby codec line refresh (1 Hz, provider-guarded)
	_rooms_acc += dt
	if _rooms_acc >= 1.0:
		_rooms_acc = 0.0
		if current == "ROOMS":
			refresh_rooms()
		if current == "ROOM":
			_update_netstats()

func _update_netstats() -> void:
	if room_net_label == null or not netstats_provider.is_valid():
		return
	room_net_label.text = str(netstats_provider.call())

func _unhandled_input(event: InputEvent) -> void:
	# Guaranteed keyboard exit: Esc steps back through overlay screens,
	# even if the mouse is captured, missing, or a widget misbehaves.
	if event.is_action_pressed("ui_cancel"):
		if current == "PAUSE":
			resume_pressed.emit()
			get_viewport().set_input_as_handled()
		elif current in ["SETTINGS", "CONTROLS", "AVATAR", "JOIN", "TOUCH_CUSTOMIZE", "ROOMS"]:
			if current == "SETTINGS":
				_sync_settings()
			go_back()
			get_viewport().set_input_as_handled()

# ---------- CONTROLS ----------
func _build_controls() -> void:
	var vb := _card("CONTROLS", "CONTROLS", 480.0)
	var rows := ["W / A / S / D — move", "Mouse — look", "Left click — fire", "Right click — aim (hold)",
		"R — reload (manual; empty gun auto-reloads)", "1 / 2 / 3 — weapons", "Shift + W — 1s sprint burst",
		"C — crouch toggle", "Z — prone toggle (crawl under fences)", "Q — avatar ability",
		"Space — jump (not while prone)", "Esc — pause", "F3 — perf overlay", "F4 — movement debug",
		"Touch: left joystick — move (analog) • drag right side — look",
		"FIRE (hold) — shoot • ADS (hold) — aim • RUN — sprint burst",
		"DUCK / PRONE — stance • RLD — reload • WPN — weapon • ABI — ability • II — pause"]
	for r in rows:
		vb.add_child(_label("•  " + r, 16))
	var back := _btn("Back")
	back.pressed.connect(func() -> void: go_back())
	vb.add_child(back)

# ---------- SETTINGS ----------
func _build_settings() -> void:
	var vb := _card("SETTINGS", "SETTINGS", 520.0)
	var sr := HBoxContainer.new()
	vb.add_child(sr)
	sr.add_child(_label("Sensitivity", 17))
	sens_slider = HSlider.new()
	sens_slider.min_value = 0.0008
	sens_slider.max_value = 0.006
	sens_slider.step = 0.0001
	sens_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sens_slider.value_changed.connect(func(v: float) -> void:
		settings.sens = v
		sens_val.text = "%0.4f" % v)
	sr.add_child(sens_slider)
	sens_val = _label("", 15)
	sr.add_child(sens_val)
	var qr := HBoxContainer.new()
	vb.add_child(qr)
	qr.add_child(_label("Graphics", 17))
	quality_opt = OptionButton.new()
	quality_opt.add_item("Low", 0)
	quality_opt.add_item("Medium", 1)
	quality_opt.add_item("High", 2)
	quality_opt.item_selected.connect(func(i: int) -> void: settings.quality = i)
	qr.add_child(quality_opt)
	var fr := HBoxContainer.new()
	vb.add_child(fr)
	fr.add_child(_label("FPS limit", 17))
	fps_opt = OptionButton.new()
	fps_opt.add_item("Uncapped", 0)
	fps_opt.add_item("30", 30)
	fps_opt.add_item("60", 60)
	fps_opt.add_item("120", 120)
	fps_opt.item_selected.connect(func(i: int) -> void:
		settings.fps_limit = int(fps_opt.get_item_id(i)))
	fr.add_child(fps_opt)
	full_check = CheckBox.new()
	full_check.text = "Fullscreen"
	full_check.toggled.connect(func(v: bool) -> void: settings.fullscreen = v)
	vb.add_child(full_check)
	invert_check = CheckBox.new()
	invert_check.text = "Invert mouse Y"
	invert_check.toggled.connect(func(v: bool) -> void: settings.invert_y = v)
	vb.add_child(invert_check)
	scope_check = CheckBox.new()
	scope_check.text = "Scope toggle (tap to aim)"
	scope_check.tooltip_text = "ON: one tap of the ADS button keeps you scoped until you tap again. OFF: hold to aim."
	scope_check.toggled.connect(func(v: bool) -> void: settings.ads_toggle = v)
	vb.add_child(scope_check)
	autoaim_check = CheckBox.new()
	autoaim_check.text = "Auto-aim assist"
	autoaim_check.tooltip_text = "While scoped or firing, gently ease the view toward an enemy already near the crosshair."
	autoaim_check.toggled.connect(func(v: bool) -> void: settings.auto_aim = v)
	vb.add_child(autoaim_check)
	approve_check = CheckBox.new()
	approve_check.text = "Require host approval to join"
	approve_check.tooltip_text = "Held joins show on the dashboard where you can accept or reject them (auto-approves after a short wait)."
	approve_check.toggled.connect(func(v: bool) -> void: settings.approve_joins = v)
	vb.add_child(approve_check)
	alert_check = CheckBox.new()
	alert_check.text = "Notify me when someone joins"
	alert_check.tooltip_text = "Desktop notification + beep on the host PC when a player asks to join. Clicking it opens the dashboard."
	alert_check.toggled.connect(func(v: bool) -> void: settings.join_alerts = v)
	vb.add_child(alert_check)
	var vr := HBoxContainer.new()
	vb.add_child(vr)
	vr.add_child(_label("Volume", 17))
	vol_slider = HSlider.new()
	vol_slider.min_value = 0.0
	vol_slider.max_value = 1.0
	vol_slider.step = 0.05
	vol_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vol_slider.value_changed.connect(func(v: float) -> void:
		settings.master_vol = v
		settings.apply(get_window())
		vol_val.text = "%d%%" % int(v * 100.0))
	vr.add_child(vol_slider)
	vol_val = _label("", 15)
	vr.add_child(vol_val)
	mute_check = CheckBox.new()
	mute_check.text = "Mute all audio"
	mute_check.toggled.connect(func(v: bool) -> void:
		settings.muted = v
		settings.apply(get_window())
	)
	vb.add_child(mute_check)
	# touch controls: visibility override + tuning (dev can force ON for PC test)
	var tr := HBoxContainer.new()
	vb.add_child(tr)
	tr.add_child(_label("Touch controls", 17))
	touch_opt = OptionButton.new()
	touch_opt.add_item("Auto", 0)
	touch_opt.add_item("Force ON", 1)
	touch_opt.add_item("Force OFF", 2)
	touch_opt.item_selected.connect(func(i: int) -> void: settings.touch_mode = i)
	tr.add_child(touch_opt)
	var ts := HBoxContainer.new()
	vb.add_child(ts)
	ts.add_child(_label("Touch look", 17))
	touch_sens_slider = HSlider.new()
	touch_sens_slider.min_value = 0.3
	touch_sens_slider.max_value = 2.5
	touch_sens_slider.step = 0.05
	touch_sens_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	touch_sens_slider.value_changed.connect(func(v: float) -> void:
		settings.touch_look_sens = v
		touch_sens_val.text = "%0.2f" % v)
	ts.add_child(touch_sens_slider)
	touch_sens_val = _label("", 15)
	ts.add_child(touch_sens_val)
	var to := HBoxContainer.new()
	vb.add_child(to)
	to.add_child(_label("Touch opacity", 17))
	touch_op_slider = HSlider.new()
	touch_op_slider.min_value = 0.3
	touch_op_slider.max_value = 1.0
	touch_op_slider.step = 0.05
	touch_op_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	touch_op_slider.value_changed.connect(func(v: float) -> void:
		settings.touch_opacity = v
		touch_op_val.text = "%0.2f" % v)
	to.add_child(touch_op_slider)
	touch_op_val = _label("", 15)
	to.add_child(touch_op_val)
	var tsc := HBoxContainer.new()
	vb.add_child(tsc)
	tsc.add_child(_label("Touch scale", 17))
	touch_scale_slider = HSlider.new()
	touch_scale_slider.min_value = 0.5
	touch_scale_slider.max_value = 2.0
	touch_scale_slider.step = 0.05
	touch_scale_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	touch_scale_slider.value_changed.connect(func(v: float) -> void:
		settings.touch_scale = v
		touch_scale_val.text = "%0.2f" % v)
	tsc.add_child(touch_scale_slider)
	touch_scale_val = _label("", 15)
	tsc.add_child(touch_scale_val)
	var tc := HBoxContainer.new()
	vb.add_child(tc)
	var cust := _btn("Customize Layout")
	cust.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cust.pressed.connect(func() -> void: show_screen("TOUCH_CUSTOMIZE"))
	tc.add_child(cust)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	vb.add_child(h)
	var save := _btn("Apply")
	save.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	save.pressed.connect(func() -> void:
		settings.save()
		settings.apply(get_window())
		apply_quality()
		go_back())
	h.add_child(save)
	var back := _btn("Back")
	back.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	back.pressed.connect(func() -> void: _sync_settings(); go_back())
	h.add_child(back)

func bind_settings(s: GameSettings) -> void:
	settings = s
	_sync_settings()

func _sync_settings() -> void:
	if settings == null or sens_slider == null:
		return
	sens_slider.value = settings.sens
	sens_val.text = "%0.4f" % settings.sens
	quality_opt.select(settings.quality)
	for i in fps_opt.item_count:
		if int(fps_opt.get_item_id(i)) == settings.fps_limit:
			fps_opt.select(i)
	full_check.button_pressed = settings.fullscreen
	invert_check.button_pressed = settings.invert_y
	scope_check.button_pressed = settings.ads_toggle
	autoaim_check.button_pressed = settings.auto_aim
	approve_check.button_pressed = settings.approve_joins
	alert_check.button_pressed = settings.join_alerts
	vol_slider.value = settings.master_vol
	vol_val.text = "%d%%" % int(settings.master_vol * 100.0)
	mute_check.button_pressed = settings.muted
	touch_opt.select(settings.touch_mode)
	touch_sens_slider.value = settings.touch_look_sens
	touch_sens_val.text = "%0.2f" % settings.touch_look_sens
	touch_op_slider.value = settings.touch_opacity
	touch_op_val.text = "%0.2f" % settings.touch_opacity
	touch_scale_slider.value = settings.touch_scale
	touch_scale_val.text = "%0.2f" % settings.touch_scale

func apply_quality() -> void:
	# Low: shadows off + grass off. Med: shadows on small. High: bigger shadows.
	var q := settings.quality if settings else 1
	var grass: Node = get_tree().current_scene.get_node_or_null("Main/Arena/Grass") if get_tree().current_scene else null
	for light in get_tree().get_nodes_in_group("sun"):
		if light is DirectionalLight3D:
			(light as DirectionalLight3D).shadow_enabled = q >= 1

# ---------- PAUSE ----------
func _build_pause() -> void:
	var vb := _card("PAUSE", "PAUSED", 420.0)
	var r := _btn("Resume")
	r.pressed.connect(func() -> void: resume_pressed.emit())
	vb.add_child(r)
	var s := _btn("Settings")
	s.pressed.connect(func() -> void: show_screen("SETTINGS"))
	vb.add_child(s)
	var q := _btn("Quit to menu")
	q.pressed.connect(func() -> void: quit_to_menu.emit())
	vb.add_child(q)

# ---------- RESULTS ----------
func _build_results() -> void:
	var vb := _card("RESULTS", "MATCH OVER", 560.0)
	results_title = _label("", 26, Color(1, 0.85, 0.4))
	results_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(results_title)
	results_rows = VBoxContainer.new()
	vb.add_child(results_rows)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	vb.add_child(h)
	var rem := _btn("Rematch")
	rem.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rem.pressed.connect(func() -> void: rematch_pressed.emit())
	h.add_child(rem)
	var men := _btn("Menu")
	men.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	men.pressed.connect(func() -> void: quit_to_menu.emit())
	h.add_child(men)
	var det := _btn("📊 Details")
	det.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	det.pressed.connect(func() -> void: details_pressed.emit())
	h.add_child(det)

func show_results(winner: int, s0: int, s1: int, rows: Array) -> void:
	for c in results_rows.get_children():
		c.queue_free()
	results_title.text = "BLUE WINS  %d — %d" % [s0, s1] if winner == 0 else ("RED WINS  %d — %d" % [s1, s0] if winner == 1 else "DRAW  %d — %d" % [s0, s1])
	results_title.add_theme_color_override("font_color",
		Color(0.45, 0.7, 1.0) if winner == 0 else (Color(1, 0.45, 0.4) if winner == 1 else Color(0.9, 0.9, 0.9)))
	for r in rows:
		var d: Dictionary = r
		var l := _label("%s   [%s]   K %d / D %d   %d pts" % [
			str(d.get("name", "?")), "BLUE" if int(d.get("team", 0)) == 0 else "RED",
			int(d.get("kills", 0)), int(d.get("deaths", 0)), int(d.get("score", 0))], 16)
		results_rows.add_child(l)
	# terminal screen: Rematch / Menu / Details are the only exits
	show_screen("RESULTS", false)

# ---------- TOUCH CUSTOMIZE ----------
func _build_touch_customize() -> void:
	var vb := _card("TOUCH_CUSTOMIZE", "CUSTOMIZE TOUCH CONTROLS", 600.0)
	vb.add_child(_label("Drag joystick and buttons to reposition. Tap Done when finished.", 16, Color(0.7, 0.9, 1.0)))
	
	# Create a full-screen overlay for drag-and-drop
	touch_customize_overlay = Control.new()
	touch_customize_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	touch_customize_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	touch_customize_overlay.visible = false
	add_child(touch_customize_overlay)
	
	# Joystick drag handle
	touch_drag_joy = _make_drag_item("JOYSTICK", Color(0.4, 0.8, 1.0), 120.0)
	touch_drag_joy.is_joystick = true
	touch_drag_joy.name = "DragJoy"
	touch_customize_overlay.add_child(touch_drag_joy)
	touch_drag_items.append(touch_drag_joy)
	
	# Button drag handles
	for spec in TouchUI.DEFAULT_BUTTONS:
		var action := str(spec[1])
		var text := str(spec[0])
		var d: float = float(spec[4])
		var b := _make_drag_item(text, Color(1.0, 0.7, 0.4), minf(d, 110.0))
		b.action = action
		b.name = "Drag_" + action
		touch_customize_overlay.add_child(b)
		touch_drag_items.append(b)
	
	# Done button
	touch_drag_done = _btn("DONE")
	touch_drag_done.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	touch_drag_done.pressed.connect(_on_touch_customize_done)
	var done_center := CenterContainer.new()
	done_center.set_anchors_preset(Control.PRESET_FULL_RECT)
	done_center.add_child(touch_drag_done)
	touch_customize_overlay.add_child(done_center)
	
	var back := _btn("Back")
	back.pressed.connect(func() -> void: go_back())
	vb.add_child(back)

func _make_drag_item(label: String, color: Color, size: float) -> DragHandle:
	var c := DragHandle.new()
	c.setup(label, color, size)
	c.moved.connect(_on_drag_moved)
	return c

func _on_drag_moved(item: DragHandle, frac: Vector2) -> void:
	if item == touch_drag_joy:
		settings.touch_joy_pos = frac
	elif item.action != "":
		settings.touch_button_positions[item.action] = frac

func _center_on_frac(item: Control, frac: Vector2) -> void:
	var vp := get_viewport().get_visible_rect().size
	var half: Vector2 = item.size * 0.5
	item.global_position = Vector2(frac.x * vp.x, frac.y * vp.y) - half

func _on_touch_customize_done() -> void:
	settings.save()
	touch_customize_overlay.visible = false
	touch_customize_closed.emit()
	go_back()

func _enter_touch_customize() -> void:
	if touch_customize_overlay == null:
		return
	touch_customize_overlay.visible = true
	var vp := get_viewport().get_visible_rect().size
	_center_on_frac(touch_drag_joy, settings.touch_joy_pos)
	for item in touch_drag_items:
		if item == touch_drag_joy:
			continue
		var f := _default_frac_for(item.action)
		if settings.touch_button_positions.has(item.action):
			f = settings.touch_button_positions[item.action]
		_center_on_frac(item, f)

func _default_frac_for(action: String) -> Vector2:
	for spec in TouchUI.DEFAULT_BUTTONS:
		if str(spec[1]) == action:
			return Vector2(float(spec[2]), float(spec[3]))
	return Vector2(0.5, 0.5)

# Override show_screen to handle TOUCH_CUSTOMIZE
func _show_touch_customize_hook(screen_name: String) -> void:
	if screen_name == "TOUCH_CUSTOMIZE":
		_enter_touch_customize()
	elif current == "TOUCH_CUSTOMIZE" and screen_name != "TOUCH_CUSTOMIZE":
		if touch_customize_overlay:
			touch_customize_overlay.visible = false
