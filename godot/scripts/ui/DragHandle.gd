class_name DragHandle
extends Control

## Draggable touch-control proxy used by the "Customize Touch Controls" screen.
## Moves itself with mouse (desktop testing) or touch, then reports the new
## fractional screen position back to Menus so it can be persisted.

signal moved(handle: DragHandle, frac: Vector2)

var is_joystick := false
var action := ""
var accent := Color(0.4, 0.8, 1.0)
var handle_diameter := 120.0

var _dragging := false
var _drag_start := Vector2.ZERO
var _item_start := Vector2.ZERO

func setup(label: String, color: Color, diameter: float) -> void:
	accent = color
	handle_diameter = diameter
	custom_minimum_size = Vector2(diameter, diameter)
	size = Vector2(diameter, diameter)
	mouse_filter = Control.MOUSE_FILTER_STOP
	pivot_offset = Vector2(diameter, diameter) * 0.5

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(color.r, color.g, color.b, 0.6)
	sb.border_color = Color(1, 1, 1, 0.9)
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(int(diameter * 0.5))
	panel.add_theme_stylebox_override("panel", sb)
	add_child(panel)

	var l := Label.new()
	l.text = label
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", int(16 * (diameter / 100.0)))
	l.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.set_anchors_preset(Control.PRESET_FULL_RECT)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(l)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		var st := event as InputEventScreenTouch
		if st.pressed:
			_begin_drag(st.position)
		elif _dragging:
			_end_drag()
	elif event is InputEventScreenDrag:
		if _dragging:
			_move((event as InputEventScreenDrag).position)
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.device == InputEvent.DEVICE_ID_EMULATION:
			return
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_begin_drag(mb.position)
			elif _dragging:
				_end_drag()
	elif event is InputEventMouseMotion:
		if event.device != InputEvent.DEVICE_ID_EMULATION and _dragging:
			_move((event as InputEventMouseMotion).position)

func _begin_drag(global_pos: Vector2) -> void:
	_dragging = true
	_drag_start = global_pos
	_item_start = global_position
	z_index = 100

func _move(global_pos: Vector2) -> void:
	global_position = _item_start + (global_pos - _drag_start)

func _end_drag() -> void:
	_dragging = false
	z_index = 0
	var vp := get_viewport().get_visible_rect().size
	if vp.x <= 0.0 or vp.y <= 0.0:
		return
	var frac := Vector2(
		clampf(global_position.x / vp.x, 0.05, 0.95),
		clampf(global_position.y / vp.y, 0.05, 0.95))
	moved.emit(self, frac)
