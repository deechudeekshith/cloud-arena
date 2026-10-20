class_name PickupItem
extends Node3D

## A floating ammo box. Bobs/spins/pulses, gives ammo on touch via the
## combatant's pickup_ammo(key, amount), then hides and respawns in place.

var weapon_key := "rifle"
var amount := 30
var respawn_time := 30.0
# net support: index in spawn order (deterministic from map seed on all
# peers), client request callback instead of local grant.
var box_index := -1
var net_client := false
var net_send: Callable

var _mesh: MeshInstance3D
var _area: Area3D
var _t := 0.0
var _taken := false
var _timer := 0.0
var _base_y := 0.6

const TYPES := [
	{"key": "rifle", "amount": 30, "color": Color(0.3, 0.85, 1.0)},
	{"key": "smg", "amount": 32, "color": Color(0.5, 1.0, 0.4)},
	{"key": "shotgun", "amount": 8, "color": Color(1.0, 0.7, 0.2)},
]

## Scatter `count` boxes near cover spots, snapped to the ground.
static func spawn_random(parent: Node, count: int, covers: Array) -> void:
	if covers.is_empty():
		return
	for i in count:
		var base: Vector3 = covers.pick_random()
		var a := randf() * TAU
		var pos := base + Vector3(cos(a) * randf_range(3.0, 8.0), 0, sin(a) * randf_range(3.0, 8.0))
		var space := (parent as Node3D).get_world_3d().direct_space_state
		var q := PhysicsRayQueryParameters3D.create(pos + Vector3(0, 20, 0), pos + Vector3(0, -5, 0))
		q.collision_mask = ArenaConfig.mask_world()
		var hit := space.intersect_ray(q)
		pos.y = 0.6
		if not hit.is_empty():
			pos = (hit["position"] as Vector3) + Vector3(0, 0.6, 0)
		var t: Dictionary = TYPES.pick_random()
		spawn_box(parent, pos, str(t["key"]), int(t["amount"]), t["color"])

static func spawn_box(parent: Node, pos: Vector3, key: String, amt: int, col: Color) -> PickupItem:
	var p := PickupItem.new()
	p.weapon_key = key
	p.amount = amt
	p.respawn_time = ArenaConfig.AMMO_PICKUP_RESPAWN
	parent.add_child(p)
	p.global_position = pos
	p._base_y = pos.y
	p._build(col)
	return p

func _build(col: Color) -> void:
	add_to_group("pickup")
	_mesh = MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.45, 0.35, 0.45)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.emission_enabled = true
	mat.emission = col
	mat.emission_energy_multiplier = 1.5
	mat.roughness = 0.3
	_mesh.material_override = mat
	_mesh.mesh = bm
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mesh)
	# bullet tips on top so it reads as ammo, not a crate
	var tips := MeshInstance3D.new()
	var tm := BoxMesh.new()
	tm.size = Vector3(0.3, 0.12, 0.3)
	var tmat := StandardMaterial3D.new()
	tmat.albedo_color = Color(0.95, 0.8, 0.4)
	tmat.metallic = 0.7
	tmat.roughness = 0.3
	tips.material_override = tmat
	tips.mesh = tm
	tips.position = Vector3(0, 0.24, 0)
	tips.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mesh.add_child(tips)
	_area = Area3D.new()
	_area.collision_layer = 0
	_area.collision_mask = ArenaConfig.mask_body()
	var cs := CollisionShape3D.new()
	var sph := SphereShape3D.new()
	sph.radius = 1.3
	cs.shape = sph
	_area.add_child(cs)
	add_child(_area)
	_area.body_entered.connect(_on_body)

## Hide + start respawn (host authority or offline). Client mirrors
## granted boxes through this without re-granting ammo.
func take_local() -> void:
	if _taken:
		return
	_taken = true
	_timer = respawn_time
	visible = false
	_area.set_deferred("monitoring", false)
	_fx_collect()

func _process(dt: float) -> void:
	_t += dt
	if _taken:
		_timer -= dt
		if _timer <= 0.0:
			_taken = false
			visible = true
			_area.set_deferred("monitoring", true)
		return
	position.y = _base_y + sin(_t * 2.5) * 0.12
	rotation.y = _t * 0.8
	var m := _mesh.material_override as StandardMaterial3D
	if m:
		m.emission_energy_multiplier = 1.2 + sin(_t * 3.0) * 0.5

func _on_body(body: Node3D) -> void:
	if _taken:
		return
	if not body.has_method("pickup_ammo"):
		return
	if net_client:
		# client: the LOCAL human asks the host, which validates + grants
		var pc := body as PlayerController
		if pc and pc.is_human and not pc.dead and net_send.is_valid():
			net_send.call(box_index)
		return
	body.pickup_ammo(weapon_key, amount)
	take_local()

func _fx_collect() -> void:
	var parent := get_parent() as Node3D
	if parent == null:
		return
	var col := (_mesh.material_override as StandardMaterial3D).albedo_color
	for i in 10:
		var q := MeshInstance3D.new()
		var qm := QuadMesh.new()
		var sz := randf_range(0.1, 0.22)
		qm.size = Vector2(sz, sz)
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = col
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		q.material_override = mat
		q.mesh = qm
		q.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parent.add_child(q)
		q.global_position = global_position
		var vel := Vector3(randf_range(-1, 1), randf_range(0.5, 2.0), randf_range(-1, 1)).normalized() * randf_range(2.0, 5.0)
		var tw := q.create_tween()
		tw.set_parallel(true)
		tw.tween_property(q, "global_position", q.global_position + vel, 0.5).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tw.tween_property(q, "transparency", 1.0, 0.5)
		tw.chain().tween_callback(q.queue_free)
