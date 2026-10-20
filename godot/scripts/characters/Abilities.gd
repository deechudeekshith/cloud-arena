class_name Abilities
extends RefCounted

## Per-avatar special abilities. State is a plain Dictionary
## {cooldown_left, active, active_left} owned by the controller.
## Controllers call trigger_* on input and tick_* every physics frame.

static func make_state() -> Dictionary:
	return {"cooldown_left": 0.0, "active": false, "active_left": 0.0}

static func tick_cooldown(state: Dictionary, dt: float) -> void:
	state["cooldown_left"] = maxf(0.0, float(state.get("cooldown_left", 0.0)) - dt)
	if bool(state.get("active", false)):
		state["active_left"] = float(state.get("active_left", 0.0)) - dt
		if float(state.get("active_left", 0.0)) <= 0.0:
			state["active"] = false

static func ready(state: Dictionary) -> bool:
	return float(state.get("cooldown_left", 0.0)) <= 0.0

# --- SCOUT: air dash (8m burst, keeps momentum feel) ---
static func scout_dash(state: Dictionary, owner: CharacterBody3D) -> void:
	var dir := -owner.global_transform.basis.z
	dir.y = 0.0
	if dir.length() < 0.1:
		dir = Vector3(0, 0, -1)
	dir = dir.normalized()
	owner.velocity = dir * 16.0 + Vector3(0, 1.5, 0)
	state["cooldown_left"] = 12.0
	state["active"] = true
	state["active_left"] = 0.2
	_fx_dash_trail(owner)

static func _fx_dash_trail(owner: Node3D) -> void:
	var tree := owner.get_tree()
	if tree == null:
		return
	for i in 8:
		var p := MeshInstance3D.new()
		var qm := QuadMesh.new()
		qm.size = Vector2(1.0, 1.0)
		var sm := StandardMaterial3D.new()
		sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		sm.albedo_color = Color(0.3, 0.85, 1.0, 0.7)
		sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		sm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		p.material_override = sm
		p.mesh = qm
		p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		tree.root.add_child(p)
		p.global_position = owner.global_position + Vector3(0, 1.2, 0) + Vector3(
			randf_range(-0.4, 0.4), randf_range(-0.2, 0.2), randf_range(-0.4, 0.4))
		var tw := p.create_tween()
		tw.set_parallel(true)
		tw.tween_property(p, "transparency", 1.0, 0.3)
		tw.tween_property(p, "position", p.position + Vector3(0, 0.5, 0), 0.3)
		tw.chain().tween_callback(p.queue_free)

# --- TROOPER: overshield (+50 max HP for 6s) ---
static func trooper_shield(state: Dictionary, owner: Node, health: Health) -> void:
	var base_max: float = ArenaConfig.MAX_HP * float(owner.get("health_mod"))
	state["cooldown_left"] = 18.0
	state["active"] = true
	state["active_left"] = 6.0
	health.max_hp = base_max + 50.0
	health.heal(50.0)
	_fx_shield_on(owner)

static func trooper_shield_end(state: Dictionary, owner: Node, health: Health) -> void:
	var base_max: float = ArenaConfig.MAX_HP * float(owner.get("health_mod"))
	health.max_hp = base_max
	health.hp = minf(health.hp, base_max)
	health.changed.emit(health.hp, health.max_hp)

static func _fx_shield_on(owner: Node3D) -> void:
	var tree := owner.get_tree()
	if tree == null:
		return
	var sph := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 1.1
	sm.height = 2.2
	sm.radial_segments = 12
	sm.rings = 6
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.3, 0.6, 1.0, 0.25)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	sph.material_override = mat
	sph.mesh = sm
	sph.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	tree.root.add_child(sph)
	sph.global_position = (owner as Node3D).global_position + Vector3(0, 1.0, 0)
	var tw := sph.create_tween()
	tw.set_parallel(true)
	tw.tween_property(sph, "scale", Vector3.ONE * 1.3, 6.0)
	tw.tween_property(sph, "transparency", 1.0, 6.0)
	tw.chain().tween_callback(sph.queue_free)

# --- MEDIC: regen beacon (visual; healing applied by caller) ---
static func medic_field(state: Dictionary, owner: Node3D) -> void:
	state["cooldown_left"] = 20.0
	state["active"] = true
	state["active_left"] = 8.0
	_fx_beacon(owner)

static func _beacon_mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(1.0, 0.3, 0.35, 0.85)
	m.emission_enabled = true
	m.emission = Color(1.0, 0.2, 0.25)
	m.emission_energy_multiplier = 1.5
	return m

static func _fx_beacon(owner: Node3D) -> void:
	var tree := owner.get_tree()
	if tree == null:
		return
	var at: Vector3 = owner.global_position + -owner.global_transform.basis.z * 1.5
	at.y = maxf(at.y, 0.9)
	var b := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.15
	cm.bottom_radius = 0.15
	cm.height = 1.8
	b.material_override = _beacon_mat()
	b.mesh = cm
	b.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	tree.root.add_child(b)
	b.global_position = at
	for i in 4:
		var r := MeshInstance3D.new()
		var tm := TorusMesh.new()
		tm.inner_radius = 0.5
		tm.outer_radius = 0.55
		var rm := StandardMaterial3D.new()
		rm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		rm.albedo_color = Color(1.0, 0.3, 0.35, 0.5)
		rm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		r.material_override = rm
		r.mesh = tm
		r.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		tree.root.add_child(r)
		r.global_position = at + Vector3(0, 0.2 + float(i) * 0.15, 0)
		var tw := r.create_tween()
		tw.set_parallel(true)
		tw.tween_property(r, "scale", Vector3.ONE * 5.0, 1.0).set_delay(float(i) * 0.9)
		tw.tween_property(r, "transparency", 1.0, 1.0).set_delay(float(i) * 0.9)
		tw.chain().tween_callback(r.queue_free)
	var twb := b.create_tween()
	twb.tween_interval(8.0)
	twb.tween_callback(b.queue_free)

# --- GHOST: cloak (hide third-person meshes 4s) ---
static func ghost_cloak(state: Dictionary, _owner: Node3D) -> void:
	state["cooldown_left"] = 22.0
	state["active"] = true
	state["active_left"] = 4.0

static func set_cloak_visible(body: Node3D, vis: bool) -> void:
	if body == null:
		return
	for n in body.get_children():
		if n is MeshInstance3D:
			(n as MeshInstance3D).visible = vis
		if n is Node3D:
			set_cloak_visible(n as Node3D, vis)
