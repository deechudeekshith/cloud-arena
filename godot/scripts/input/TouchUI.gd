class_name TouchUI
extends CanvasLayer

## Mobile/touch control layer. Feeds the SHARED GameInput.Touch provider —
## the same interface the PC provider implements, so gameplay code never
## branches on platform. Multi-touch safe: joystick, look area and buttons
## each track their own touch index. Lightweight: flat buttons + 2 custom
## controls, no shaders, no textures.

var provider: GameInput.Touch
var look_gain := 2.2 # touch px -> mouse-px-equivalent (x look_sens later)
var btn_opacity := 0.85
var ui_scale := 1.0
var settings: GameSettings

var _joy: TouchJoystick
var _look: TouchLookArea
var _btn_layer: Control
var _buttons: Array[TouchButton] = []
# Set by GameRoot: mobile pause button target (toggle_pause).
var pause_requested: Callable
# Mobile pause button (test API + visibility control).
var pause_btn: BaseButton

# fractional layout: [text, action, fx, fy, diameter]
const DEFAULT_BUTTONS := [
	["FIRE", "fire", 0.905, 0.70, 132.0],
	["JUMP", "jump", 0.775, 0.80, 92.0],
	["RUN", "sprint", 0.905, 0.47, 86.0],
	["DUCK", "crouch", 0.795, 0.585, 82.0],
	["PRONE", "prone", 0.64, 0.44, 82.0],
	["ADS", "aim", 0.835, 0.575, 70.0],
	["RLD", "reload", 0.905, 0.30, 78.0],
	["WPN", "weapon_cycle", 0.815, 0.30, 78.0],
	["ABI", "ability", 0.725, 0.30, 78.0],
]
const DEFAULT_JOY_FRAC := Vector2(0.13, 0.62)
const JOY_RADIUS := 95.0

var buttons_layout: Dictionary = {}
var joy_frac: Vector2 = DEFAULT_JOY_FRAC

func _ready() -> void:
	layer = 30
	provider = GameInput.Touch.new()
	_look = TouchLookArea.new()
	_look.touch_ui = self
	# right ~60% of screen, full height, BEHIND buttons
	_look.set_anchors_preset(Control.PRESET_FULL_RECT)
	_look.anchor_left = 0.38
	_look.anchor_right = 1.0
	_look.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_look)
	_joy = TouchJoystick.new()
	_joy.touch_ui = self
	add_child(_joy)
	_btn_layer = Control.new()
	_btn_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	_btn_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_btn_layer)
	for spec in DEFAULT_BUTTONS:
		var b := TouchButton.new(str(spec[1]))
		b.caption = str(spec[0])
		b.focus_mode = Control.FOCUS_NONE
		b.mouse_filter = Control.MOUSE_FILTER_STOP
		var action := str(spec[1])
		b.button_down.connect(func() -> void: provider.press(action))
		b.button_up.connect(func() -> void: provider.release(action))
		_btn_layer.add_child(b)
		_buttons.append(b)
	# mobile pause button (top-right, fixed; Esc equivalent on touch)
	var pb := TouchButton.new("pause")
	pb.name = "PauseButton"
	pb.caption = ""
	pb.focus_mode = Control.FOCUS_NONE
	pb.mouse_filter = Control.MOUSE_FILTER_STOP
	pb.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	pb.position = Vector2(-76, 12)
	pb.custom_minimum_size = Vector2(64, 48)
	pb.size = Vector2(64, 48)
	pb.pressed.connect(func() -> void:
		if pause_requested.is_valid():
			pause_requested.call())
	add_child(pb)
	pause_btn = pb
	get_viewport().size_changed.connect(_layout)
	_apply_layout_from_settings()
	_apply_style()

func _layout() -> void:
	var vp := get_viewport().get_visible_rect().size
	# joystick: fixed pixel radius scaled, anchored by fraction
	var jr := JOY_RADIUS * ui_scale
	_joy.anchor_left = joy_frac.x
	_joy.anchor_top = joy_frac.y
	_joy.anchor_right = joy_frac.x
	_joy.anchor_bottom = joy_frac.y
	_joy.offset_left = -jr
	_joy.offset_top = -jr
	_joy.offset_right = jr
	_joy.offset_bottom = jr
	_joy.base_radius = jr
	_joy.queue_redraw()
	for i in _buttons.size():
		var spec: Array = DEFAULT_BUTTONS[i]
		var b := _buttons[i]
		var action := str(spec[1])
		var d: float = float(spec[4]) * ui_scale
		var fx: float = joy_frac.x
		var fy: float = joy_frac.y
		if buttons_layout.has(action):
			var pos: Vector2 = buttons_layout[action]
			fx = pos.x
			fy = pos.y
		else:
			fx = float(spec[2])
			fy = float(spec[3])
		b.anchor_left = fx
		b.anchor_top = fy
		b.anchor_right = fx
		b.anchor_bottom = fy
		b.offset_left = -d * 0.5
		b.offset_top = -d * 0.5
		b.offset_right = d * 0.5
		b.offset_bottom = d * 0.5
		b.queue_redraw()

func _apply_layout_from_settings() -> void:
	if settings == null:
		buttons_layout = {}
		joy_frac = DEFAULT_JOY_FRAC
		_layout()
		return
	joy_frac = settings.touch_joy_pos
	buttons_layout = {}
	for action in settings.touch_button_positions:
		buttons_layout[action] = settings.touch_button_positions[action]
	_layout()

func apply_settings(touch_look_sens: float, opacity: float, scale: float) -> void:
	look_gain = 2.2 * touch_look_sens
	btn_opacity = opacity
	ui_scale = scale
	_apply_style()
	_layout()

func _apply_style() -> void:
	_btn_layer.modulate.a = btn_opacity
	_joy.modulate.a = btn_opacity
	_look.modulate.a = btn_opacity

func apply_settings_full(s: GameSettings) -> void:
	settings = s
	look_gain = 2.2 * s.touch_look_sens
	btn_opacity = s.touch_opacity
	ui_scale = s.touch_scale
	_apply_layout_from_settings()
	_apply_style()

func set_match_visible(v: bool) -> void:
	visible = v

## Test API: screen-space joystick center for synthetic touches.
func joystick_center_global() -> Vector2:
	var vp := get_viewport().get_visible_rect().size
	return Vector2(joy_frac.x * vp.x, joy_frac.y * vp.y)

func joystick_radius() -> float:
	return JOY_RADIUS * ui_scale

## Test API: a point safely inside the look area.
func look_point_global() -> Vector2:
	var vp := get_viewport().get_visible_rect().size
	return Vector2(0.7 * vp.x, 0.5 * vp.y)

## Test API: center of a button by action name.
func button_center_global(action: String) -> Vector2:
	var vp := get_viewport().get_visible_rect().size
	var f := Vector2(0.5, 0.5)
	if buttons_layout.has(action):
		f = buttons_layout[action]
	else:
		for spec in DEFAULT_BUTTONS:
			if str(spec[1]) == action:
				f = Vector2(float(spec[2]), float(spec[3]))
				break
	return Vector2(f.x * vp.x, f.y * vp.y)

## Virtual joystick: press-drag-release, one tracked touch, deadzone in
## provider. Also accepts mouse (PC testing with forced touch UI).
class TouchJoystick extends Control:
	var touch_ui: TouchUI
	var base_radius := 95.0
	var thumb := Vector2.ZERO
	var _touch_idx := -1
	var _mouse_down := false

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventScreenTouch:
			var st := event as InputEventScreenTouch
			if st.pressed and _touch_idx < 0 and not _mouse_down:
				if (st.position - size * 0.5).length() <= base_radius * 1.4:
					_touch_idx = st.index
					_update_thumb(st.position)
			elif not st.pressed and st.index == _touch_idx:
				_touch_idx = -1
				thumb = Vector2.ZERO
				touch_ui.provider.set_move(Vector2.ZERO)
				queue_redraw()
		elif event is InputEventScreenDrag:
			var sd := event as InputEventScreenDrag
			if sd.index == _touch_idx:
				_update_thumb(sd.position)
		elif event is InputEventMouseButton:
			var mb := event as InputEventMouseButton
			if mb.device == InputEvent.DEVICE_ID_EMULATION:
				pass # real touch already handled above; avoid double-drive
			elif mb.button_index == MOUSE_BUTTON_LEFT:
				if mb.pressed and _touch_idx < 0:
					_mouse_down = true
					_update_thumb(mb.position)
				elif not mb.pressed and _mouse_down:
					_mouse_down = false
					thumb = Vector2.ZERO
					touch_ui.provider.set_move(Vector2.ZERO)
					queue_redraw()
		elif event is InputEventMouseMotion:
			if event.device == InputEvent.DEVICE_ID_EMULATION:
				pass
			elif _mouse_down:
				_update_thumb((event as InputEventMouseMotion).position)

	func _update_thumb(local: Vector2) -> void:
		var off := local - size * 0.5
		if off.length() > base_radius:
			off = off.normalized() * base_radius
		thumb = off
		# screen y down -> forward is -y
		touch_ui.provider.set_move(Vector2(off.x / base_radius, -off.y / base_radius))
		queue_redraw()

	func _draw() -> void:
		var c := size * 0.5
		draw_circle(c, base_radius, Color(1, 1, 1, 0.10))
		draw_arc(c, base_radius, 0, TAU, 48, Color(1, 1, 1, 0.35), 3.0)
		draw_circle(c + thumb, base_radius * 0.42, Color(1, 1, 1, 0.30))

## Right-side look surface. Tracks ONE drag; buttons above it consume
## their own touches first (sibling order), so no look jump on fire.
class TouchLookArea extends Control:
	var touch_ui: TouchUI
	var _touch_idx := -1
	var _last := Vector2.ZERO
	var _mouse_down := false

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventScreenTouch:
			var st := event as InputEventScreenTouch
			if st.pressed and _touch_idx < 0 and not _mouse_down:
				_touch_idx = st.index
				_last = st.position
			elif not st.pressed and st.index == _touch_idx:
				_touch_idx = -1
		elif event is InputEventScreenDrag:
			var sd := event as InputEventScreenDrag
			if sd.index == _touch_idx:
				_push(sd.position - _last)
				_last = sd.position
		elif event is InputEventMouseButton:
			var mb := event as InputEventMouseButton
			if mb.device == InputEvent.DEVICE_ID_EMULATION:
				pass
			elif mb.button_index == MOUSE_BUTTON_LEFT:
				if mb.pressed and _touch_idx < 0:
					_mouse_down = true
					_last = mb.position
				elif not mb.pressed:
					_mouse_down = false
		elif event is InputEventMouseMotion:
			if event.device == InputEvent.DEVICE_ID_EMULATION:
				pass
			elif _mouse_down and _touch_idx < 0:
				var mm := event as InputEventMouseMotion
				_push(mm.position - _last)
				_last = mm.position

	func _push(d: Vector2) -> void:
		# screen drag right -> yaw right; drag up (d.y<0, screen y down) ->
		# pitch up. Both match the PC look convention (right+, up+).
		touch_ui.provider.add_look(Vector2(-d.x, -d.y) * touch_ui.look_gain)

## Glossy reflective icon button: dark glass disc, bright top-half
## reflection swipe, white vector icon per action + tiny caption.
## Extends BaseButton so press/hold/release semantics (and the touch
## emulation path) are identical to a normal Button.
class TouchButton extends BaseButton:
	var action := ""
	var caption := ""
	var _down := false
	var bg := Color(0.04, 0.07, 0.13, 0.62)
	var bg_down := Color(0.10, 0.30, 0.55, 0.80)

	func _init(p_action := "") -> void:
		action = p_action
		button_down.connect(func() -> void: _down = true; queue_redraw())
		button_up.connect(func() -> void: _down = false; queue_redraw())

	func _draw() -> void:
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.5
		if r <= 1.0:
			return
		# glass disc
		draw_circle(c, r, bg_down if _down else bg)
		# rim light
		draw_arc(c, r - 1.5, 0, TAU, 48, Color(0.55, 0.8, 1.0, 0.5), 2.0)
		# reflective gloss: squashed highlight in the top half
		draw_set_transform(c + Vector2(0, -r * 0.34), 0.0, Vector2(1.0, 0.52))
		draw_circle(Vector2.ZERO, r * 0.60, Color(1, 1, 1, 0.22 if _down else 0.15))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		# bottom shade for depth
		draw_arc(c, r * 0.82, PI * 0.15, PI * 0.85, 32, Color(0, 0, 0, 0.30), r * 0.18)
		var off := Vector2(0, 1.5) if _down else Vector2.ZERO
		_draw_icon(c + off, r)
		if caption != "":
			var f: Font = ThemeDB.fallback_font
			var fs := int(clampf(r * 0.26, 10.0, 17.0))
			var tw := f.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			draw_string(f, c + off + Vector2(-tw * 0.5, r * 0.78),
				caption, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1, 0.8))

	func _chev(p: Vector2, k: float, up: bool, col: Color, w: float) -> void:
		var s := -1.0 if up else 1.0
		draw_line(p + Vector2(-k, s * k * 0.45), p + Vector2(0, -s * k * 0.55), col, w, true)
		draw_line(p + Vector2(0, -s * k * 0.55), p + Vector2(k, s * k * 0.45), col, w, true)

	func _head(tip: Vector2, dir: Vector2, col: Color, s: float) -> void:
		var side := Vector2(-dir.y, dir.x) * s * 0.5
		draw_colored_polygon([tip, tip - dir * s + side, tip - dir * s - side], col)

	func _draw_icon(c: Vector2, r: float) -> void:
		var ic := Color(1, 1, 1, 0.93)
		var w := maxf(2.5, r * 0.11)
		var k := r * 0.40
		match action:
			"fire": # crosshair: dot + 4 ticks
				draw_circle(c, w * 0.7, ic)
				for d in [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)]:
					draw_line(c + d * k * 0.45, c + d * k, ic, w, true)
			"jump": # chevron up + ground line
				_chev(c + Vector2(0, -k * 0.15), k * 0.8, true, ic, w)
				draw_line(c + Vector2(-k * 0.8, k * 0.75), c + Vector2(k * 0.8, k * 0.75), ic, w, true)
			"sprint": # double chevron right
				for ox in [-k * 0.45, k * 0.15]:
					var p := c + Vector2(ox, 0)
					draw_line(p + Vector2(-k * 0.35, -k * 0.7), p + Vector2(k * 0.35, 0), ic, w, true)
					draw_line(p + Vector2(k * 0.35, 0), p + Vector2(-k * 0.35, k * 0.7), ic, w, true)
			"crouch": # chevron down over ground line
				_chev(c + Vector2(0, -k * 0.25), k * 0.7, false, ic, w)
				draw_line(c + Vector2(-k * 0.8, k * 0.7), c + Vector2(k * 0.8, k * 0.7), ic, w, true)
			"prone": # lying figure: long + short bars
				draw_line(c + Vector2(-k, -k * 0.25), c + Vector2(k, -k * 0.25), ic, w, true)
				draw_line(c + Vector2(-k * 0.55, k * 0.35), c + Vector2(k * 0.55, k * 0.35), ic, w, true)
			"aim": # scope: ring + cross
				draw_arc(c, k * 0.8, 0, TAU, 32, ic, w)
				draw_line(c + Vector2(-k, 0), c + Vector2(k, 0), ic, w * 0.8, true)
				draw_line(c + Vector2(0, -k), c + Vector2(0, k), ic, w * 0.8, true)
			"reload": # circular arrow
				draw_arc(c, k * 0.75, 0.5, TAU - 0.5, 32, ic, w)
				var tip := c + Vector2(cos(0.5), sin(0.5)) * k * 0.75
				_head(tip, Vector2(cos(0.5 + PI * 0.5), sin(0.5 + PI * 0.5)), ic, w * 2.2)
			"weapon_cycle": # swap arrows
				var y := k * 0.35
				draw_line(c + Vector2(-k * 0.8, -y), c + Vector2(k * 0.8, -y), ic, w, true)
				_head(c + Vector2(k * 0.8, -y), Vector2(1, 0), ic, w * 2.0)
				draw_line(c + Vector2(k * 0.8, y), c + Vector2(-k * 0.8, y), ic, w, true)
				_head(c + Vector2(-k * 0.8, y), Vector2(-1, 0), ic, w * 2.0)
			"ability": # lightning bolt
				var s := k / 10.0
				draw_colored_polygon([
					c + Vector2(1.5, -10) * s, c + Vector2(-4.5, 1.5) * s,
					c + Vector2(-0.8, 1.5) * s, c + Vector2(-1.5, 10) * s,
					c + Vector2(4.5, -1.5) * s, c + Vector2(0.8, -1.5) * s,
				], ic)
			"pause": # two bars
				var bw := maxf(3.0, r * 0.12)
				draw_rect(Rect2(c + Vector2(-k * 0.55, -k * 0.8), Vector2(bw, k * 1.6)), ic)
				draw_rect(Rect2(c + Vector2(k * 0.55 - bw, -k * 0.8), Vector2(bw, k * 1.6)), ic)
			_: # fallback: ring
				draw_arc(c, k * 0.7, 0, TAU, 32, ic, w)
