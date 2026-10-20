class_name HealthBar
extends Control

## Good-looking HP bar, drawn fully custom (no theme fragility):
## rounded background, white damage-ghost that drains after hits,
## green→yellow→red gradient fill, gloss highlight, 25% segment ticks,
## subtle border that pulses red at low HP, white hit flash overlay.

var hp := 100.0
var max_hp := 100.0
var ghost := 100.0
var flash := 0.0
var t := 0.0

var _bg := StyleBoxFlat.new()
var _fill := StyleBoxFlat.new()
var _ghost_sb := StyleBoxFlat.new()
var _border := StyleBoxFlat.new()
var _border_low := StyleBoxFlat.new()

func _init() -> void:
	custom_minimum_size = Vector2(300, 24)
	_bg.bg_color = Color(0.04, 0.05, 0.08, 0.85)
	_bg.set_corner_radius_all(7)
	_fill.set_corner_radius_all(5)
	_ghost_sb.bg_color = Color(1.0, 0.92, 0.88, 0.8)
	_ghost_sb.set_corner_radius_all(5)
	_border.draw_center = false
	_border.set_corner_radius_all(7)
	_border.set_border_width_all(2)
	_border.border_color = Color(1, 1, 1, 0.22)
	_border_low.draw_center = false
	_border_low.set_corner_radius_all(7)
	_border_low.set_border_width_all(2)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func set_hp(v: float, m: float) -> void:
	max_hp = maxf(1.0, m)
	if v > hp + 0.5:
		ghost = v # healed / respawned: snap ghost up, no drain
		flash = 1.0
	elif v < hp - 0.5:
		flash = maxf(flash, 0.55)
	hp = clampf(v, 0.0, max_hp)
	ghost = clampf(ghost, hp, max_hp)
	queue_redraw()

func _process(dt: float) -> void:
	t += dt
	if ghost > hp:
		ghost = maxf(hp, ghost - max_hp * 0.5 * dt)
		queue_redraw()
	if flash > 0.0:
		flash = maxf(0.0, flash - dt * 2.5)
		queue_redraw()
	# low-hp border pulse needs continuous redraw
	if max_hp > 0.0 and hp / max_hp < 0.32:
		queue_redraw()

static func color_for(frac: float) -> Color:
	var f := clampf(frac, 0.0, 1.0)
	if f > 0.5:
		return Color(0.98, 0.82, 0.22).lerp(Color(0.32, 0.92, 0.38), (f - 0.5) * 2.0)
	return Color(0.96, 0.24, 0.18).lerp(Color(0.98, 0.82, 0.22), f * 2.0)

func _draw() -> void:
	var frac := clampf(hp / max_hp, 0.0, 1.0)
	var gfrac := clampf(ghost / max_hp, 0.0, 1.0)
	var r := Rect2(Vector2.ZERO, size)
	draw_style_box(_bg, r)
	var inset := 3.0
	var bar := Rect2(inset, inset, size.x - inset * 2.0, size.y - inset * 2.0)
	if bar.size.x <= 0.0:
		return
	# damage ghost (recently lost HP, drains down to current)
	if gfrac > 0.004:
		var gw := Rect2(bar.position, Vector2(bar.size.x * gfrac, bar.size.y))
		draw_style_box(_ghost_sb, gw)
	# main fill
	if frac > 0.004:
		_fill.bg_color = color_for(frac)
		var fw := Rect2(bar.position, Vector2(bar.size.x * frac, bar.size.y))
		draw_style_box(_fill, fw)
		# gloss highlight on the filled portion
		var gh := Rect2(bar.position + Vector2(3, 2),
			Vector2(maxf(0.0, bar.size.x * frac - 6.0), maxf(0.0, (bar.size.y - 4.0) * 0.38)))
		if gh.size.x > 1.0:
			draw_rect(gh, Color(1, 1, 1, 0.16))
	# 25% segment ticks
	for i in range(1, 4):
		var x := bar.position.x + bar.size.x * float(i) / 4.0
		draw_line(Vector2(x, bar.position.y + 2.0), Vector2(x, bar.end.y - 2.0),
			Color(0, 0, 0, 0.5), 2.0)
	# border (pulsing red when critical)
	draw_style_box(_border, r)
	if frac < 0.32 and frac > 0.0:
		var pulse := 0.45 + 0.4 * sin(t * 7.0)
		_border_low.border_color = Color(1.0, 0.15, 0.1, pulse)
		draw_style_box(_border_low, r.grow(1.0))
	# white hit flash
	if flash > 0.01:
		draw_rect(r.grow(-1.0), Color(1, 1, 1, flash * 0.3))
