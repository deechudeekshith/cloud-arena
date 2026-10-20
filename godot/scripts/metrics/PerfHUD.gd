class_name PerfHUD
extends CanvasLayer

## Persistent optional perf overlay. Real measurements only:
## FPS, frame ms, process RAM. Network rows show honest N/A offline.
## F3 toggles. Includes tiny FPS graph.

var label: RichTextLabel
var graph: Control
var visible_hud := true
var _fps_hist: Array = []
var net_info := {"ping": -1.0, "rtt": -1.0, "loss": -1.0, "up": -1.0, "down": -1.0,
	"comp_ratio": -1.0, "comp_ms": -1.0, "decomp_ms": -1.0, "saved": -1}

func _ready() -> void:
	layer = 90
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.position = Vector2(8, 8)
	panel.custom_minimum_size = Vector2(225, 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.55)
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	panel.add_theme_stylebox_override("panel", sb)
	add_child(panel)
	var vb := VBoxContainer.new()
	panel.add_child(vb)
	label = RichTextLabel.new()
	label.bbcode_enabled = true
	label.fit_content = true
	label.scroll_active = false
	label.custom_minimum_size = Vector2(210, 0)
	vb.add_child(label)
	graph = Graph.new()
	graph.custom_minimum_size = Vector2(210, 36)
	vb.add_child(graph)

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("perf_toggle"):
		visible_hud = not visible_hud
		for ch in get_children():
			(ch as Control).visible = visible_hud

func _process(_dt: float) -> void:
	if not visible_hud:
		return
	var fps := Engine.get_frames_per_second()
	_fps_hist.append(fps)
	if _fps_hist.size() > 120:
		_fps_hist.pop_front()
	graph.queue_redraw()
	var ms := 1000.0 / maxf(1.0, float(fps))
	var ram_mb := float(OS.get_static_memory_usage()) / 1048576.0
	var vram := "N/A"
	var draw_calls := Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	var verts := Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	label.text = "[font_size=12][color=#8fd6ff]PERF[/color]  [color=#ffffff]%d FPS  %0.1f ms[/color]\n[color=#9a9a9a]RAM %0.0f MB  draw %d  prim %d  VRAM %s[/color]\n[color=#9a9a9a]NET: ping N/A  rtt N/A  loss N/A\nup N/A  down N/A  comp N/A  saved N/A[/color][/font_size]" % [fps, ms, ram_mb, draw_calls, verts, vram]

class Graph extends Control:
	func _draw() -> void:
		var hud := get_parent().get_parent().get_parent() as PerfHUD
		if hud == null or hud._fps_hist.is_empty():
			return
		var w := size.x
		var h := size.y
		draw_rect(Rect2(0, 0, w, h), Color(0, 0, 0, 0.4))
		# 60fps line
		draw_line(Vector2(0, h - h * 60.0 / 90.0), Vector2(w, h - h * 60.0 / 90.0), Color(0.4, 1, 0.5, 0.5))
		var n: int = hud._fps_hist.size()
		for i in n:
			var f: float = hud._fps_hist[i]
			var x := w * i / 120.0
			var bh: float = h * clamp(f / 90.0, 0.0, 1.0)
			var c := Color(0.4, 1, 0.5) if f >= 50.0 else (Color(1, 0.85, 0.3) if f >= 30.0 else Color(1, 0.35, 0.3))
			draw_line(Vector2(x, h), Vector2(x, h - bh), c)
