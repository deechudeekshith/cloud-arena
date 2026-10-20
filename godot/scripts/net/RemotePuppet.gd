class_name RemotePuppet
extends Node3D

## Visual-only remote combatant. No physics, no collision, no AI.
## Renders host snapshots with ~100ms interpolation delay for smooth
## motion. Muzzle flash fires on shooting rising edges; death/crouch/
## prone poses come from the snapshot animation state.

var player_id := -1
var display_name := "?"
var team_id := 0
var avatar_id := 0
var dead := false

var body_visual: Node3D
var body_parts := {}
var tp_gun: Node3D

var _buf: Array = [] # recent snapshots, oldest-first
var _anim_t := 0.0
var _was_shooting := false
var _death_t := 0.0
const INTERP_DELAY := 0.1

func setup(p_id: int, p_team: int, p_avatar: int, pname: String) -> void:
	player_id = p_id
	team_id = p_team
	avatar_id = p_avatar
	display_name = pname
	var built: Dictionary = HumanoidBuilder.build(AvatarDB.get_preset(avatar_id), team_id)
	body_visual = built["root"]
	body_parts = built["parts"]
	add_child(body_visual)

func set_weapon(wid: int, skin: int = 0) -> void:
	if tp_gun and is_instance_valid(tp_gun):
		tp_gun.queue_free()
	tp_gun = WeaponViewBuilder.build_worldmodel(wid, skin)
	HumanoidBuilder.attach_weapon_to_hand(body_parts, tp_gun)

func apply_snapshot(s: Dictionary, now: float) -> void:
	_buf.append({"t": now, "s": s})
	while _buf.size() > 8:
		_buf.pop_front()
	var wid := int(s.get("weapon_id", 0))
	if tp_gun == null or not is_instance_valid(tp_gun):
		set_weapon(wid)
	var alive := float(s.get("health", 0.0)) > 0.0
	if dead and alive:
		_death_t = 0.0
	dead = not alive

func _process(dt: float) -> void:
	_anim_t += dt
	if _buf.is_empty():
		return
	var rt: float = float((_buf.back() as Dictionary)["t"]) - INTERP_DELAY
	# find bracketing snapshots
	var a: Dictionary = (_buf.back() as Dictionary)["s"]
	var pa := Vector3.ZERO
	var pb := Vector3.ZERO
	var ya := 0.0
	var yb := 0.0
	var found := false
	var b: Dictionary = _buf.back()["s"]
	if _buf.size() >= 2:
		for i in range(_buf.size() - 1):
			var t0: float = _buf[i]["t"]
			var t1: float = _buf[i + 1]["t"]
			if rt >= t0 and rt <= t1:
				a = _buf[i]["s"]
				b = _buf[i + 1]["s"]
				var k := 0.0 if t1 <= t0 else clampf((rt - t0) / (t1 - t0), 0.0, 1.0)
				pa = _v3(a.get("position", Vector3.ZERO))
				pb = _v3(b.get("position", Vector3.ZERO))
				ya = float((a.get("rotation", Vector2.ZERO) as Vector2).x)
				yb = float((b.get("rotation", Vector2.ZERO) as Vector2).x)
				global_position = pa.lerp(pb, k)
				rotation.y = lerp_angle(ya, yb, k)
				found = true
				break
	if not found:
		var last: Dictionary = b
		global_position = _v3(last.get("position", Vector3.ZERO))
		rotation.y = float((last.get("rotation", Vector2.ZERO) as Vector2).x)
		a = last
	# pose from the (older) sample
	var hspeed := _v3(a.get("velocity", Vector3.ZERO))
	var hs := Vector2(hspeed.x, hspeed.z).length()
	var pitch := float((a.get("rotation", Vector2.ZERO) as Vector2).y)
	var shooting := bool(a.get("shooting", false))
	if shooting and not _was_shooting and tp_gun:
		FX.muzzle(tp_gun)
	_was_shooting = shooting
	if dead:
		_death_t += dt
	var crouch := str(a.get("stance", "")).begins_with("CROUCH")
	var prone := str(a.get("stance", "")).begins_with("PRONE") or str(a.get("stance", "")).begins_with("CRAWL")
	AnimController.pose(body_parts, body_visual, dt, {
		"time": _anim_t, "speed": hs, "airborne": false,
		"vy": 0.0, "sprinting": hs > 5.0, "crouch": crouch, "prone": prone,
		"prone_blend": 1.0 if prone else 0.0,
		"firing": shooting, "reload_t": 0.0 if not bool(a.get("reloading", false)) else 0.5,
		"hit_t": 99.0, "dead": dead, "death_t": _death_t,
		"aim_pitch": pitch, "spawn_t": 99.0,
	})
	# cloak: hide meshes while active
	var cloaked := bool(a.get("cloaked", false))
	if body_visual.visible == cloaked:
		body_visual.visible = not cloaked

static func _v3(v: Variant) -> Vector3:
	if v is Vector3:
		return v
	if v is Array and (v as Array).size() >= 3:
		return Vector3(float(v[0]), float(v[1]), float(v[2]))
	return Vector3.ZERO
