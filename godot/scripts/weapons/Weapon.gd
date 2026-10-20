class_name Weapon
extends Node

## Runtime weapon instance. Data comes from WeaponDB (never hardcoded in
## player/bot scripts). Handles cooldown, spread pellets, reload, recoil.
## Hitscan via direct space state; damage applied through a Callable so
## this class never touches game score logic directly.

signal ammo_changed(mag: int, reserve: int)
signal reloaded
signal fired
signal empty_clicked # fresh trigger press with mag==0 (UI click sound)

var data: Dictionary
var mag: int = 30
var reserve: int = 120
var cooldown := 0.0
var reloading := false
var reload_left := 0.0
var trigger_held := false
var _was_held := false
var auto_reload := true # fire-on-empty reloads; R always reloads manually

static func max_reserve_for(key: String) -> int:
	match key:
		"rifle":
			return ArenaConfig.MAX_RESERVE_RIFLE
		"smg":
			return ArenaConfig.MAX_RESERVE_SMG
		"shotgun":
			return ArenaConfig.MAX_RESERVE_SHOTGUN
	return 999

static func create(weapon_id: int) -> Weapon:
	var wpn := Weapon.new()
	wpn.data = WeaponDB.get_weapon(weapon_id)
	wpn.mag = int(wpn.data["mag"])
	wpn.reserve = max_reserve_for(str(wpn.data["key"]))
	wpn.name = "Weapon_%s" % str(wpn.data["key"])
	return wpn

func weapon_id() -> int:
	return int(data["id"])

func display_name() -> String:
	return str(data["name"])

func is_auto() -> bool:
	return bool(data["auto"])

func can_fire() -> bool:
	return cooldown <= 0.0 and not reloading and mag > 0

func tick(dt: float) -> void:
	cooldown = maxf(0.0, cooldown - dt)
	if reloading:
		reload_left -= dt
		if reload_left <= 0.0:
			reloading = false
			var need: int = int(data["mag"]) - mag
			var take: int = mini(need, reserve)
			mag += take
			reserve -= take
			reloaded.emit()
			ammo_changed.emit(mag, reserve)

func start_reload() -> bool:
	if reloading or mag >= int(data["mag"]) or reserve <= 0:
		return false
	reloading = true
	reload_left = float(data["reload_time"])
	return true

func reload_progress() -> float:
	# -1 = not reloading, else 0..1
	if not reloading:
		return -1.0
	var total: float = float(data["reload_time"])
	return clamp(1.0 - reload_left / total, 0.0, 1.0)

## Returns recoil kick applied (radians) for camera. 0 if no shot.
## spread_mult tightens the cone (ADS passes ~0.55, bots pass 1.0).
func try_fire(space: PhysicsDirectSpaceState3D, from: Vector3, base_dir: Vector3,
		shooter_id: int, deal: Callable, tracer_cb: Callable, spread_mult := 1.0) -> float:
	var want := trigger_held if is_auto() else (trigger_held and not _was_held)
	var fresh := trigger_held and not _was_held
	_was_held = trigger_held
	if not want:
		return 0.0
	if reloading:
		return 0.0
	if cooldown > 0.0:
		return 0.0
	if mag <= 0:
		if fresh:
			empty_clicked.emit()
		if auto_reload:
			start_reload()
		return 0.0
	mag -= 1
	cooldown = 1.0 / float(data["fire_rate"])
	ammo_changed.emit(mag, reserve)
	fired.emit()
	var spread_rad := deg_to_rad(float(data["spread_deg"])) * spread_mult
	var pellets: int = int(data["pellets"])
	var dmg: float = float(data["damage"])
	var head_mult: float = float(data["head_mult"])
	var rng: float = float(data["range"])
	var total_kick := 0.0
	for i in pellets:
		var dir := _spread_dir(base_dir, spread_rad)
		var to := from + dir * rng
		var hit := _query(space, from, to)
		if hit.is_empty():
			tracer_cb.call(from, to)
			continue
		var pos: Vector3 = hit["position"]
		var collider: Node = hit["collider"] as Node
		tracer_cb.call(from, pos)
		var is_head: bool = collider != null and collider.is_in_group("head_hitbox")
		var target: Node = null
		if is_head:
			target = _owner_of_head(collider)
		elif collider is Node and (collider as Node).is_in_group("combatant"):
			target = collider
		if target != null and target.has_method("apply_hit"):
			var final := dmg * (head_mult if is_head else 1.0)
			deal.call(target, final, shooter_id, is_head, pos, hit.get("normal", Vector3.UP), "flesh")
		else:
			deal.call(null, 0.0, shooter_id, false, pos, hit.get("normal", Vector3.UP), FX.surface_of(collider))
	total_kick = float(data["recoil"]) * (1.0 if pellets <= 1 else 1.6)
	return total_kick

var _exclude: Array[RID] = []

func set_self_exceptions(rids: Array[RID]) -> void:
	_exclude = rids.duplicate()

func _query(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = ArenaConfig.mask_shot()
	q.collide_with_areas = true
	q.collide_with_bodies = true
	q.exclude = _exclude
	return space.intersect_ray(q)

func _spread_dir(d: Vector3, spread: float) -> Vector3:
	if spread <= 0.0:
		return d.normalized()
	var right := d.cross(Vector3.UP)
	if right.length() < 0.01:
		right = Vector3.RIGHT
	right = right.normalized()
	var up := right.cross(d).normalized()
	var a := randf() * TAU
	var r := sqrt(randf()) * spread
	return (d + right * cos(a) * r + up * sin(a) * r).normalized()

func _owner_of_head(area: Object) -> Node:
	var n := area as Node
	while n != null:
		if n.is_in_group("combatant"):
			return n
		n = n.get_parent()
	return null

## Procedural UI click (empty trigger, reload clack base). No assets.
static func make_click_stream(freq := 2400.0, dur := 0.05) -> AudioStreamWAV:
	var rate := 22050
	var n := int(rate * dur)
	var bytes := PackedByteArray()
	bytes.resize(n)
	for i in n:
		var t := float(i) / rate
		var env := exp(-t * 90.0)
		var s: float = clamp(sin(TAU * freq * t) * 0.6 * env, -1.0, 1.0)
		bytes[i] = int((s * 0.5 + 0.5) * 255.0)
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_8_BITS
	wav.mix_rate = rate
	wav.data = bytes
	return wav

## Procedural placeholder gunshot (no audio assets needed).
static func make_shot_stream(kind: int) -> AudioStreamWAV:
	var rate := 22050
	var dur := 0.09 if kind != 2 else 0.22
	var n := int(rate * dur)
	var bytes := PackedByteArray()
	bytes.resize(n)
	for i in n:
		var t := float(i) / rate
		var env := exp(-t * (38.0 if kind != 2 else 22.0))
		var noise := randf_range(-1.0, 1.0)
		var tone := sin(TAU * (180.0 if kind == 1 else 120.0) * t) * 0.4
		var s: float = clamp((noise * 0.8 + tone) * env, -1.0, 1.0)
		bytes[i] = int((s * 0.5 + 0.5) * 255.0)
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_8_BITS
	wav.mix_rate = rate
	wav.data = bytes
	return wav
