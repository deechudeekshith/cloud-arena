class_name FX
extends RefCounted

## Lightweight pooled-feel effects: tracers, impact puffs, muzzle flash,
## blood-less hit spark + death poof. All procedural, shared materials,
## auto-freed. iGPU friendly (no big particle textures).

static var _spark_mat: StandardMaterial3D
static var _tracer_mat: StandardMaterial3D
static var _metal_mat: StandardMaterial3D
static var _wood_mat: StandardMaterial3D
static var _rock_mat: StandardMaterial3D

# pooled high-frequency effects (no per-shot allocation)
static var _tracer_pool: Array[MeshInstance3D] = []
static var _tracer_mesh: BoxMesh
static var _tracer_idx := 0
static var _shell_pool: Array[MeshInstance3D] = []
static var _shell_mesh: BoxMesh
static var _shell_mat: StandardMaterial3D
static var _shell_idx := 0

static func _mats() -> void:
	if _spark_mat == null:
		_spark_mat = StandardMaterial3D.new()
		_spark_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_spark_mat.albedo_color = Color(1.0, 0.85, 0.5)
		_spark_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		_spark_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if _tracer_mat == null:
		_tracer_mat = StandardMaterial3D.new()
		_tracer_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_tracer_mat.albedo_color = Color(1.0, 0.9, 0.55, 0.85)
		_tracer_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_tracer_mat.emission_enabled = true
		_tracer_mat.emission = Color(1.0, 0.8, 0.4)
	if _metal_mat == null:
		_metal_mat = StandardMaterial3D.new()
		_metal_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_metal_mat.albedo_color = Color(1.0, 0.95, 0.8)
		_metal_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		_metal_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_metal_mat.emission_enabled = true
		_metal_mat.emission = Color(1.0, 0.7, 0.3)
	if _wood_mat == null:
		_wood_mat = StandardMaterial3D.new()
		_wood_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_wood_mat.albedo_color = Color(0.72, 0.5, 0.28)
		_wood_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		_wood_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if _rock_mat == null:
		_rock_mat = StandardMaterial3D.new()
		_rock_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_rock_mat.albedo_color = Color(0.75, 0.74, 0.7)
		_rock_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		_rock_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

## Preallocate pooled nodes under one parent (call once from GameRoot).
static func ensure_pools(parent: Node3D, tracers := 24, shells := 14) -> void:
	_mats()
	if _tracer_mesh == null:
		_tracer_mesh = BoxMesh.new()
		_tracer_mesh.size = Vector3(0.02, 0.02, 1.0)
		_tracer_mesh.material = _tracer_mat
	while _tracer_pool.size() < tracers:
		var mi := MeshInstance3D.new()
		mi.mesh = _tracer_mesh
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visible = false
		parent.add_child(mi)
		_tracer_pool.append(mi)
	if _shell_mesh == null:
		_shell_mesh = BoxMesh.new()
		_shell_mesh.size = Vector3(0.025, 0.025, 0.045)
		_shell_mat = StandardMaterial3D.new()
		_shell_mat.albedo_color = Color(0.95, 0.75, 0.3)
		_shell_mat.metallic = 0.8
		_shell_mat.roughness = 0.3
		_shell_mesh.material = _shell_mat
	while _shell_pool.size() < shells:
		var sh := MeshInstance3D.new()
		sh.mesh = _shell_mesh
		sh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		sh.visible = false
		parent.add_child(sh)
		_shell_pool.append(sh)

static func _pool_take(pool: Array, idx: int) -> Array:
	var mi: MeshInstance3D = pool[idx % pool.size()]
	if mi.has_meta("tw"):
		var old_tw: Tween = mi.get_meta("tw") as Tween
		if old_tw and old_tw.is_valid():
			old_tw.kill()
	return [mi, (idx + 1) % pool.size()]

static func tracer(parent: Node3D, from: Vector3, to: Vector3, life := 0.07) -> void:
	_mats()
	var length := from.distance_to(to)
	if length < 0.5:
		return
	if _tracer_pool.is_empty():
		ensure_pools(parent)
	var got := _pool_take(_tracer_pool, _tracer_idx)
	var mi: MeshInstance3D = got[0]
	_tracer_idx = int(got[1])
	mi.visible = true
	mi.transparency = 0.0
	mi.global_position = (from + to) * 0.5
	mi.look_at(to, Vector3.UP)
	mi.scale = Vector3(1, 1, length)
	var tw := mi.create_tween()
	mi.set_meta("tw", tw)
	tw.tween_property(mi, "transparency", 1.0, life)
	tw.tween_callback(func() -> void: mi.visible = false)

## Ejected brass: short gravity arc, then back to the pool.
static func shell(parent: Node3D, pos: Vector3, right: Vector3) -> void:
	_mats()
	if _shell_pool.is_empty():
		ensure_pools(parent)
	var got := _pool_take(_shell_pool, _shell_idx)
	var sh: MeshInstance3D = got[0]
	_shell_idx = int(got[1])
	sh.visible = true
	sh.transparency = 0.0
	sh.global_position = pos
	sh.rotation = Vector3(randf() * TAU, randf() * TAU, 0)
	var out := right.normalized() * randf_range(0.8, 1.6) + Vector3(randf_range(-0.3, 0.3), 0, randf_range(-0.3, 0.3))
	var peak: Vector3 = pos + out * 0.4 + Vector3(0, 0.7, 0)
	var land: Vector3 = pos + out + Vector3(0, -0.9, 0)
	var tw := sh.create_tween()
	sh.set_meta("tw", tw)
	tw.set_parallel(true)
	tw.tween_property(sh, "global_position", peak, 0.16).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(sh, "rotation", sh.rotation + Vector3(7.0, 3.0, 0), 0.5)
	tw.chain().set_parallel(true)
	tw.tween_property(sh, "global_position", land, 0.34).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(func() -> void: sh.visible = false)

## Surface tags come from ArenaBuilder groups (surf_dust/metal/wood/rock).
static func surface_of(collider: Node) -> String:
	if collider == null:
		return "dust"
	for s in ["surf_metal", "surf_wood", "surf_rock", "surf_dust"]:
		if collider.is_in_group(s):
			return s.trim_prefix("surf_")
	return "rock"

static func impact(parent: Node3D, pos: Vector3, normal: Vector3, big := false, surface := "dust") -> void:
	_mats()
	# per-surface look: sparks always, dust puff only on dusty ground/rock
	var spark_mat := _spark_mat
	var count := 6 if not big else 12
	var want_puff := surface == "dust" or surface == "rock"
	match surface:
		"metal":
			spark_mat = _metal_mat
			count += 4
			want_puff = false
		"wood":
			spark_mat = _wood_mat
			want_puff = false
		"rock":
			spark_mat = _rock_mat
		"flesh":
			spark_mat = _spark_mat
			count += 2
			want_puff = false
	for i in count:
		var q := MeshInstance3D.new()
		var qm := QuadMesh.new()
		var s := 0.08 + randf() * (0.1 if not big else 0.2)
		if surface == "metal":
			s *= 0.7
		qm.size = Vector2(s, s)
		q.mesh = qm
		q.material_override = spark_mat
		q.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parent.add_child(q)
		q.global_position = pos + normal * 0.05
		var spread := 5.0 if surface != "metal" else 8.0
		var vel := (normal + Vector3(randf_range(-1, 1), randf_range(0.2, 1.2), randf_range(-1, 1))).normalized() * randf_range(2.0, spread)
		var tw := q.create_tween().set_parallel(true)
		tw.tween_property(q, "global_position", pos + vel * 0.3, 0.3).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tw.tween_property(q, "transparency", 1.0, 0.3)
		tw.chain().tween_callback(q.queue_free)
	if not want_puff:
		return
	# dust puff
	var puff := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.18 if not big else 0.35
	sm.height = 0.36 if not big else 0.7
	puff.mesh = sm
	var pm := StandardMaterial3D.new()
	pm.albedo_color = Color(0.7, 0.68, 0.62, 0.5) if surface == "dust" else Color(0.6, 0.6, 0.6, 0.4)
	pm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	pm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	puff.material_override = pm
	puff.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(puff)
	puff.global_position = pos + normal * 0.15
	var tw2 := puff.create_tween().set_parallel(true)
	tw2.tween_property(puff, "scale", Vector3.ONE * 2.2, 0.4)
	tw2.tween_property(puff, "transparency", 1.0, 0.4)
	tw2.chain().tween_callback(puff.queue_free)

static func death_poof(parent: Node3D, pos: Vector3, team_col: Color) -> void:
	impact(parent, pos + Vector3(0, 1, 0), Vector3.UP, true)
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.4
	tm.outer_radius = 0.55
	ring.mesh = tm
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(team_col, 0.7)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring.material_override = m
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(ring)
	ring.global_position = pos + Vector3(0, 0.15, 0)
	var tw := ring.create_tween().set_parallel(true)
	tw.tween_property(ring, "scale", Vector3.ONE * 2.5, 0.45)
	tw.tween_property(ring, "transparency", 1.0, 0.45)
	tw.chain().tween_callback(ring.queue_free)

static func muzzle(viewmodel: Node3D) -> void:
	if viewmodel == null:
		return
	var flash: OmniLight3D = viewmodel.get_node_or_null("MuzzleFlash") as OmniLight3D
	if flash:
		flash.light_energy = 2.5
		var tw := flash.create_tween()
		tw.tween_property(flash, "light_energy", 0.0, 0.08)
	var quad: MeshInstance3D = viewmodel.get_node_or_null("FlashQuad")
	if quad:
		quad.visible = true
		quad.rotation.z = randf() * TAU
		var s := randf_range(0.8, 1.3)
		quad.scale = Vector3.ONE * s
		var tw2 := quad.create_tween()
		tw2.tween_interval(0.05)
		tw2.tween_callback(func() -> void: quad.visible = false)
