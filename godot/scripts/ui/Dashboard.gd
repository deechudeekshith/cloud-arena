class_name Dashboard
extends CanvasLayer

## Post-match results: mode/stats from stored summary, 8 real graphs from
## stored samples, and NORMAL-vs-OPTIMIZED comparison with compatibility
## check + percentage differences. Every number comes from storage;
## missing data renders as N/A, never invented.

signal closed

var storage := MatchStorage.LocalProvider.new()
var bg: ColorRect
var panel: PanelContainer
var vb: VBoxContainer
var title_label: Label
var content: VBoxContainer
var pick_a: OptionButton
var pick_b: OptionButton

func _ready() -> void:
	layer = 60
	visible = false
	bg = ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.02, 0.03, 0.06, 0.94)
	add_child(bg)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	panel = PanelContainer.new()
	panel.custom_minimum_size = Vector2(860, 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.07, 0.10, 0.17, 0.98)
	sb.border_color = Color(0.3, 0.7, 1.0)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 24
	sb.content_margin_right = 24
	sb.content_margin_top = 18
	sb.content_margin_bottom = 18
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)
	vb = VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	panel.add_child(vb)
	title_label = _lab("", 26, Color(0.55, 0.85, 1.0))
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title_label)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(880, 540)
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vb.add_child(scroll)
	content = VBoxContainer.new()
	content.add_theme_constant_override("separation", 6)
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.custom_minimum_size = Vector2(840, 0)
	scroll.add_child(content)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	h.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_child(h)
	var close := Button.new()
	close.text = "Close"
	close.custom_minimum_size = Vector2(160, 40)
	close.pressed.connect(func() -> void:
		visible = false
		closed.emit())
	h.add_child(close)

func _lab(t: String, size: int, c: Color = Color(0.9, 0.93, 1.0)) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", c)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l

func _clear() -> void:
	for c in content.get_children():
		c.queue_free()

static func fmt(v: float, digits := 1) -> String:
	if v < 0.0:
		return "N/A"
	return "%0.*f" % [digits, v]

# ---------------- browser ----------------
func show_browser() -> void:
	_clear()
	title_label.text = "MATCH RESULTS"
	var matches := storage.list_matches()
	if matches.is_empty():
		content.add_child(_lab("No stored matches yet. Play a match first.", 16))
	else:
		content.add_child(_lab("Select a match to inspect:", 16))
		for m in matches:
			var s: Dictionary = m["summary"]
			var b := Button.new()
			b.text = "%s   [%s]  fps %s  sent %sB" % [str(m["id"]),
				str(s.get("mode", "?")), fmt(float(s.get("avg_fps", -1.0)), 0),
				fmt(float(s.get("bytes_sent", -1.0)), 0)]
			b.alignment = HORIZONTAL_ALIGNMENT_LEFT
			var mid := str(m["id"])
			b.pressed.connect(func() -> void: show_match(mid))
			content.add_child(b)
		content.add_child(_lab("Compare NORMAL vs OPTIMIZED:", 18, Color(1.0, 0.85, 0.4)))
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 8)
		content.add_child(h)
		pick_a = OptionButton.new()
		pick_b = OptionButton.new()
		for m in matches:
			pick_a.add_item(str(m["id"]))
			pick_b.add_item(str(m["id"]))
		if matches.size() > 1:
			pick_b.select(1)
		h.add_child(pick_a)
		h.add_child(pick_b)
		var cmp := Button.new()
		cmp.text = "COMPARE"
		cmp.pressed.connect(func() -> void:
			show_compare(pick_a.get_item_text(pick_a.selected), pick_b.get_item_text(pick_b.selected)))
		h.add_child(cmp)
	visible = true

# ---------------- single match ----------------
func show_match(match_id: String) -> void:
	_clear()
	var s := storage.load_summary(match_id)
	if s.is_empty():
		title_label.text = "MATCH NOT FOUND"
		visible = true
		return
	var meta := MatchStorage.LocalProvider.load_meta(match_id)
	title_label.text = "MATCH %s  [%s]" % [match_id, str(s.get("mode", "?"))]
	_add_kv("Players/Bots", "%s / %s" % [str(meta.get("humans", "?")), str(meta.get("bots", "?"))])
	_add_kv("Duration", "%ds (samples %d)" % [int(s.get("duration", 0)), int(s.get("samples", 0))])
	_add_kv("Avg FPS", fmt(float(s.get("avg_fps", -1.0))))
	_add_kv("Avg RTT / Ping", "%s / %s ms" % [fmt(float(s.get("avg_rtt", -1.0))), fmt(float(s.get("avg_ping", -1.0)))])
	_add_kv("Packet loss", fmt(float(s.get("avg_loss", -1.0)) * 100.0) + (" %" if float(s.get("avg_loss", -1.0)) >= 0.0 else ""))
	_add_kv("CPU / RAM", "%s %% / %s MB" % [fmt(float(s.get("avg_cpu", -1.0))), fmt(float(s.get("avg_ram", -1.0)))])
	_add_kv("Sent / Received", "%s / %s B" % [fmt(float(s.get("bytes_sent", -1.0)), 0), fmt(float(s.get("bytes_received", -1.0)), 0)])
	_add_kv("Compression ratio", fmt(float(s.get("compression_ratio", -1.0)), 3) + "  (comp/orig)")
	_add_kv("Bytes saved", fmt(float(s.get("bytes_saved", -1.0)), 0))
	_add_kv("Comp / decomp time", "%s / %s ms" % [
		fmt(float(s.get("comp_us_total", -1.0)) / 1000.0), fmt(float(s.get("decomp_us_total", -1.0)) / 1000.0)])
	_add_kv("Kills / Deaths", "%d / %d" % [int(s.get("kills", 0)), int(s.get("deaths", 0))])
	var rows := storage.load_rows(match_id)
	var graphs := [["fps", "FPS vs TIME", Color(0.4, 1.0, 0.5)],
		["rtt", "RTT vs TIME (ms)", Color(0.5, 0.85, 1.0)],
		["ping", "PING vs TIME (ms)", Color(0.5, 0.85, 1.0)],
		["cpu", "CPU vs TIME (%)", Color(1.0, 0.8, 0.3)],
		["ram", "RAM vs TIME (MB)", Color(1.0, 0.6, 0.4)],
		["bytes_sent", "BYTES SENT vs TIME", Color(0.7, 0.6, 1.0)],
		["bytes_received", "BYTES RECEIVED vs TIME", Color(0.7, 0.6, 1.0)],
		["ratio", "COMPRESSION RATIO vs TIME", Color(1.0, 0.5, 0.8)]]
	for g in graphs:
		content.add_child(_lab(str(g[1]), 15, Color(0.7, 0.8, 0.95)))
		var gv := GraphView.new()
		gv.setup(str(g[0]), rows, g[2])
		gv.custom_minimum_size = Vector2(800, 90)
		content.add_child(gv)
	var back := Button.new()
	back.text = "Back to list"
	back.pressed.connect(func() -> void: show_browser())
	content.add_child(back)
	visible = true

func _add_kv(k: String, v: String) -> void:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 12)
	content.add_child(h)
	var kl := _lab(k, 15, Color(0.6, 0.7, 0.85))
	kl.custom_minimum_size = Vector2(220, 0)
	h.add_child(kl)
	var vv := _lab(v, 15)
	vv.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	vv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(vv)

# ---------------- comparison ----------------
static func side_of(mode: String) -> String:
	return "OPTIMIZED" if "OPTIMIZED" in mode else "NORMAL"

func show_compare(id_a: String, id_b: String) -> void:
	_clear()
	var sa := storage.load_summary(id_a)
	var sb := storage.load_summary(id_b)
	var ma := MatchStorage.LocalProvider.load_meta(id_a)
	var mb := MatchStorage.LocalProvider.load_meta(id_b)
	title_label.text = "NORMAL vs OPTIMIZED"
	if sa.is_empty() or sb.is_empty():
		content.add_child(_lab("Could not load one of the matches.", 16))
		visible = true
		return
	# normalize: a = NORMAL side, b = OPTIMIZED side
	if side_of(str(sa.get("mode", ""))) == "OPTIMIZED" and side_of(str(sb.get("mode", ""))) == "NORMAL":
		var t := sa
		sa = sb
		sb = t
		var t2 := ma
		ma = mb
		mb = t2
		var t3 := id_a
		id_a = id_b
		id_b = t3
	content.add_child(_lab("%s [%s]  vs  %s [%s]" % [id_a, str(sa.get("mode", "?")), id_b, str(sb.get("mode", "?"))], 16))
	# compatibility (strict set blocks, the rest warns)
	var probs: Array = []
	for k in ["map", "map_seed", "player_count", "bots", "duration", "game_version"]:
		if str(ma.get(k, "?")) != str(mb.get(k, "?")):
			probs.append("%s differs (%s vs %s)" % [k, str(ma.get(k, "?")), str(mb.get(k, "?"))])
	var warns: Array = []
	if str(ma.get("net", "?")) != str(mb.get("net", "?")):
		warns.append("network config differs (%s vs %s)" % [str(ma.get("net", "?")), str(mb.get("net", "?"))])
	if side_of(str(sa.get("mode", ""))) == side_of(str(sb.get("mode", ""))):
		warns.append("both matches are on the %s side" % side_of(str(sa.get("mode", ""))))
	if not probs.is_empty():
		content.add_child(_lab("Not directly comparable:\n" + "\n".join(probs), 16, Color(1.0, 0.4, 0.35)))
		visible = true
		return
	for w in warns:
		content.add_child(_lab("Note: " + w, 14, Color(1.0, 0.8, 0.4)))
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	content.add_child(header)
	var hh_lab := _lab("metric", 15, Color(0.6, 0.7, 0.85))
	hh_lab.custom_minimum_size = Vector2(200, 0)
	header.add_child(hh_lab)
	for h in ["NORMAL", "OPTIMIZED", "change"]:
		var hh := _lab(h, 15, Color(0.6, 0.7, 0.85))
		hh.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		header.add_child(hh)
	_cmp_row( "Avg FPS", float(sa.get("avg_fps", -1.0)), float(sb.get("avg_fps", -1.0)), 1, true)
	_cmp_row( "Avg RTT ms", float(sa.get("avg_rtt", -1.0)), float(sb.get("avg_rtt", -1.0)), 1, false)
	_cmp_row( "Avg ping ms", float(sa.get("avg_ping", -1.0)), float(sb.get("avg_ping", -1.0)), 1, false)
	_cmp_row( "Loss %", float(sa.get("avg_loss", -1.0)) * 100.0, float(sb.get("avg_loss", -1.0)) * 100.0, 1, false)
	_cmp_row( "Avg CPU %", float(sa.get("avg_cpu", -1.0)), float(sb.get("avg_cpu", -1.0)), 1, false)
	_cmp_row( "Avg RAM MB", float(sa.get("avg_ram", -1.0)), float(sb.get("avg_ram", -1.0)), 1, false)
	_cmp_row( "Bytes sent", float(sa.get("bytes_sent", -1.0)), float(sb.get("bytes_sent", -1.0)), 0, false)
	_cmp_row( "Bytes recv", float(sa.get("bytes_received", -1.0)), float(sb.get("bytes_received", -1.0)), 0, false)
	_cmp_row( "Comp ratio", float(sa.get("compression_ratio", -1.0)), float(sb.get("compression_ratio", -1.0)), 3, false)
	_cmp_row( "Bytes saved", float(sa.get("bytes_saved", -1.0)), float(sb.get("bytes_saved", -1.0)), 0, true)
	_cmp_row( "Comp ms", float(sa.get("comp_us_total", -1.0)) / 1000.0, float(sb.get("comp_us_total", -1.0)) / 1000.0, 1, false)
	var back := Button.new()
	back.text = "Back to list"
	back.pressed.connect(func() -> void: show_browser())
	content.add_child(back)
	visible = true

func _cmp_row(label: String, a: float, b: float, digits: int, higher_better: bool) -> void:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 12)
	content.add_child(h)
	var kl := _lab(label, 15)
	kl.custom_minimum_size = Vector2(200, 0)
	h.add_child(kl)
	var la := _lab(fmt(a, digits), 15)
	la.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(la)
	var lb := _lab(fmt(b, digits), 15)
	lb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(lb)
	if a < 0.0 or b < 0.0 or a == 0.0:
		var na := _lab("N/A", 15)
		na.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(na)
		return
	var pct := 100.0 * (b - a) / a
	var good := (pct >= 0.0) == higher_better
	var l := _lab("%+.1f%%" % pct, 15, Color(0.4, 1.0, 0.5) if good else Color(1.0, 0.5, 0.45))
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(l)

## Real-data polyline graph. Negative samples = N/A gaps (no line drawn).
class GraphView extends Control:
	var key := ""
	var rows: Array = []
	var col := Color.WHITE

	func setup(k: String, r: Array, c: Color) -> void:
		key = k
		rows = r
		col = c
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var w := size.x
		var h := size.y
		draw_rect(Rect2(0, 0, w, h), Color(0, 0, 0, 0.45))
		var vals: Array = []
		for r in rows:
			vals.append(float((r as Dictionary).get(key, -1.0)))
		var good := vals.filter(func(v: float) -> bool: return v >= 0.0)
		if good.is_empty():
			draw_string(ThemeDB.fallback_font, Vector2(8, h * 0.6), "N/A",
				HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(0.6, 0.6, 0.65))
			return
		var lo: float = good.min()
		var hi: float = good.max()
		if hi - lo < 0.001:
			hi = lo + 1.0
		# gridlines
		for i in 3:
			var gy := h * (0.15 + 0.7 * float(i) / 2.0)
			draw_line(Vector2(0, gy), Vector2(w, gy), Color(1, 1, 1, 0.08))
		var n := vals.size()
		var prev := Vector2(-1, -1)
		for i in n:
			var v: float = vals[i]
			if v < 0.0:
				prev = Vector2(-1, -1)
				continue
			var x := w * float(i) / float(maxi(1, n - 1))
			var y := h * 0.9 - h * 0.8 * (v - lo) / (hi - lo)
			if prev.x >= 0.0:
				draw_line(prev, Vector2(x, y), col, 2.0)
			prev = Vector2(x, y)
		draw_string(ThemeDB.fallback_font, Vector2(6, 16), "%s" % _fmt_top(hi),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.7, 0.75, 0.85))
		draw_string(ThemeDB.fallback_font, Vector2(6, h - 6), "%s" % _fmt_top(lo),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.7, 0.75, 0.85))

	func _fmt_top(v: float) -> String:
		if v >= 1000.0:
			return "%0.1fk" % (v / 1000.0)
		return "%0.1f" % v
