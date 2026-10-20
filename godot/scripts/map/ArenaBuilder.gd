class_name ArenaBuilder
extends RefCounted

## Original circular arena battlefield (~130m diameter). Modular procedural
## construction: ground, roads, central hotspot, compounds, warehouses,
## containers, barriers, rocks, trees, ramps, bridge, lamps, sky, fog.
## All materials shared + flat-shaded for iGPU. Returns spawn/cover data.

const RADIUS := 62.0

static var _mats := {}

static func mat(name: String, c: Color, rough := 0.9, emis: Color = Color(0, 0, 0)) -> StandardMaterial3D:
	if _mats.has(name):
		return _mats[name]
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	m.metallic = 0.0
	if emis != Color(0, 0, 0):
		m.emission_enabled = true
		m.emission = emis
		m.emission_energy_multiplier = 0.8
	_mats[name] = m
	return m

static func _solid_box(parent: Node3D, pos: Vector3, size: Vector3, m: Material, rot_y := 0.0, surface := "rock") -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = ArenaConfig.mask_world()
	body.collision_mask = 0
	body.position = pos
	body.rotation.y = rot_y
	body.add_to_group("surf_" + surface)
	parent.add_child(body)
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	col.shape = shape
	body.add_child(col)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	bm.material = m
	mi.mesh = bm
	body.add_child(mi)
	return body

static func _deco_box(parent: Node3D, pos: Vector3, size: Vector3, m: Material, rot_y := 0.0) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	bm.material = m
	mi.mesh = bm
	mi.position = pos
	mi.rotation.y = rot_y
	parent.add_child(mi)
	return mi

static func build(parent: Node3D, map_seed := 0) -> Dictionary:
	_mats.clear()
	if map_seed != 0:
		seed(map_seed) # deterministic layout for reproducible experiments
	var covers: Array = []
	# ---- lighting + sky ----
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-52, -35, 0)
	sun.light_energy = 1.1
	sun.light_color = Color(1.0, 0.96, 0.9)
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 160.0
	sun.shadow_bias = 0.05
	parent.add_child(sun)
	var env := WorldEnvironment.new()
	env.name = "WorldEnv"
	var e := Environment.new()
	e.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var psm := ProceduralSkyMaterial.new()
	psm.sky_top_color = Color(0.25, 0.5, 0.85)
	psm.sky_horizon_color = Color(0.7, 0.82, 0.92)
	psm.ground_bottom_color = Color(0.2, 0.22, 0.25)
	psm.ground_horizon_color = Color(0.65, 0.7, 0.72)
	psm.sun_angle_max = 12.0
	sky.sky_material = psm
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 0.42
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	e.fog_enabled = true
	e.fog_light_color = Color(0.72, 0.79, 0.86)
	e.fog_density = 0.0018
	e.fog_sky_affect = 0.25
	e.fog_height_density = 0.0
	e.ssao_enabled = false
	e.glow_enabled = false
	env.environment = e
	parent.add_child(env)
	# ---- ground ----
	var ground_mat: Material = mat("ground", Color(0.29, 0.42, 0.23))
	var gbody := StaticBody3D.new()
	gbody.name = "Ground"
	gbody.collision_layer = ArenaConfig.mask_world()
	gbody.collision_mask = 0
	gbody.add_to_group("surf_dust")
	parent.add_child(gbody)
	var gcol := CollisionShape3D.new()
	var gshape := BoxShape3D.new()
	gshape.size = Vector3(RADIUS * 2.4, 1.0, RADIUS * 2.4)
	gcol.shape = gshape
	gcol.position = Vector3(0, -0.5, 0)
	gbody.add_child(gcol)
	var disc := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = RADIUS
	cm.bottom_radius = RADIUS
	cm.height = 0.2
	cm.radial_segments = 48
	cm.material = ground_mat
	disc.mesh = cm
	disc.position = Vector3(0, -0.1, 0)
	gbody.add_child(disc)
	# outer dirt ring
	var ring := MeshInstance3D.new()
	var rm := CylinderMesh.new()
	rm.top_radius = RADIUS + 14.0
	rm.bottom_radius = RADIUS + 14.0
	rm.height = 0.1
	rm.radial_segments = 48
	rm.material = mat("dirt", Color(0.42, 0.35, 0.24))
	ring.mesh = rm
	ring.position = Vector3(0, -0.18, 0)
	parent.add_child(ring)
	# ---- roads (dark strips, close/mid/long lanes) ----
	var road_m: Material = mat("road", Color(0.22, 0.22, 0.24), 0.95)
	_deco_box(parent, Vector3(0, 0.02, 0), Vector3(7, 0.06, RADIUS * 2.0), road_m)
	_deco_box(parent, Vector3(0, 0.02, 0), Vector3(RADIUS * 2.0, 0.06, 7), road_m)
	# ---- perimeter wall (keeps everyone inside, big sightline blocker) ----
	var wall_m: Material = mat("wall", Color(0.5, 0.52, 0.55))
	for i in 24:
		var a := TAU * i / 24.0
		var p := Vector3(cos(a) * (RADIUS + 1.5), 1.5, sin(a) * (RADIUS + 1.5))
		_solid_box(parent, p, Vector3(16.5, 3.0, 1.2), wall_m, -a + PI * 0.5)
	# ---- central hotspot: raised octagon plaza + pillars + crates ----
	var plaza_m: Material = mat("plaza", Color(0.45, 0.44, 0.42))
	var plaza := StaticBody3D.new()
	plaza.name = "Plaza"
	plaza.collision_layer = ArenaConfig.mask_world()
	plaza.collision_mask = 0
	plaza.position = Vector3(0, 0.5, 0)
	parent.add_child(plaza)
	var pcol := CollisionShape3D.new()
	var pshape := CylinderShape3D.new()
	pshape.radius = 9.0
	pshape.height = 1.0
	pcol.shape = pshape
	plaza.add_child(pcol)
	var pmesh := MeshInstance3D.new()
	var pcyl := CylinderMesh.new()
	pcyl.top_radius = 9.0
	pcyl.bottom_radius = 9.5
	pcyl.height = 1.0
	pcyl.radial_segments = 8
	pcyl.material = plaza_m
	pmesh.mesh = pcyl
	plaza.add_child(pmesh)
	# ramps up (N + S)
	_ramps(parent, plaza_m)
	# center monument (cover + landmark)
	_solid_box(parent, Vector3(0, 2.2, 0), Vector3(2.4, 2.4, 2.4), mat("stone", Color(0.55, 0.53, 0.5)))
	_solid_box(parent, Vector3(0, 3.9, 0), Vector3(1.4, 1.0, 1.4), mat("accent", Color(0.2, 0.6, 0.9), 0.6, Color(0.1, 0.4, 0.8)))
	covers.append(Vector3(2.5, 1.0, 0))
	covers.append(Vector3(-2.5, 1.0, 0))
	# crates on plaza
	var crate_m: Material = mat("crate", Color(0.6, 0.45, 0.28))
	_solid_box(parent, Vector3(4.5, 1.6, 3.5), Vector3(1.2, 1.2, 1.2), crate_m, 0.3, "wood")
	_solid_box(parent, Vector3(-4.5, 1.6, -3.5), Vector3(1.2, 1.2, 1.2), crate_m, -0.2, "wood")
	_solid_box(parent, Vector3(4.5, 2.7, 3.5), Vector3(0.9, 0.9, 0.9), crate_m, 0.7, "wood")
	covers.append(Vector3(4.5, 1.0, 5.2))
	covers.append(Vector3(-4.5, 1.0, -5.2))
	# ---- 4 compounds (diagonal quadrants, close-range interiors) ----
	_compound(parent, Vector3(28, 0, 28), 0.4, covers)
	_compound(parent, Vector3(-28, 0, 28), -0.4, covers)
	_compound(parent, Vector3(28, 0, -28), -0.4, covers)
	_compound(parent, Vector3(-28, 0, -28), 0.4, covers)
	# ---- 2 warehouses (mid-range, open front + roof) ----
	_warehouse(parent, Vector3(-30, 0, 0), PI * 0.5, covers)
	_warehouse(parent, Vector3(30, 0, 0), -PI * 0.5, covers)
	# ---- container yard (scattered + stacked, medium cover) ----
	_containers(parent, covers)
	# ---- concrete barriers (lane cover) ----
	var bar_m: Material = mat("barrier", Color(0.7, 0.7, 0.68))
	var bar_positions := [Vector3(12, 0, 8), Vector3(-12, 0, -8), Vector3(12, 0, -8),
		Vector3(-12, 0, 8), Vector3(0, 0, 18), Vector3(0, 0, -18),
		Vector3(18, 0, 0), Vector3(-18, 0, 0)]
	for bp in bar_positions:
		bp = (bp as Vector3) + Vector3(randf_range(-1.5, 1.5), 0, randf_range(-1.5, 1.5))
		_solid_box(parent, bp + Vector3(0, 0.55, 0), Vector3(3.0, 1.1, 0.6), bar_m, randf() * 0.6)
		covers.append(bp + Vector3(0, 0, 1.2))
	# ---- rocks (natural cover, long sightline breaks) ----
	var rock_m: Material = mat("rock", Color(0.45, 0.45, 0.47))
	var rock_spots := [Vector3(15, 0, -20), Vector3(-16, 0, 20), Vector3(22, 0, 12),
		Vector3(-22, 0, -12), Vector3(8, 0, -30), Vector3(-8, 0, 30)]
	for rp in rock_spots:
		rp = (rp as Vector3) + Vector3(randf_range(-2.0, 2.0), 0, randf_range(-2.0, 2.0))
		var rb := StaticBody3D.new()
		rb.collision_layer = ArenaConfig.mask_world()
		rb.collision_mask = 0
		rb.position = rp + Vector3(0, 0.6, 0)
		parent.add_child(rb)
		var rc := CollisionShape3D.new()
		var rs := SphereShape3D.new()
		rs.radius = 1.4
		rc.shape = rs
		rb.add_child(rc)
		var rmi := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 1.4
		sm.height = 2.2
		sm.radial_segments = 8
		sm.rings = 5
		sm.material = rock_m
		rmi.mesh = sm
		rmi.scale = Vector3(1.2, 0.9, 1.0)
		rb.add_child(rmi)
		covers.append(rp + Vector3(1.8, 0, 0))
	# ---- bridge (elevated lane between warehouses, vertical combat) ----
	_bridge(parent, covers)
	# ---- movement test course (south field: fences, gates, tunnel, stairs) ----
	_movement_course(parent)
	# ---- trees + grass + lamps + dust ----
	_trees(parent)
	_grass(parent)
	_lamps(parent)
	EnvironmentFX.dust(parent)
	EnvironmentFX.banners(parent)
	# ---- spawns: blue west, red east ----
	var sb: Array = []
	var sr: Array = []
	for i in 4:
		sb.append(Vector3(-46, 0.5, -18 + i * 12))
		sr.append(Vector3(46, 0.5, -18 + i * 12))
	return {"spawns_blue": sb, "spawns_red": sr, "covers": covers, "radius": RADIUS}

static func _movement_course(parent: Node3D) -> void:
	# South-field training course. Clearances are real collision:
	# red fence -> 0.6m gap (prone only), yellow gate -> 1.2m (crouch+),
	# concrete tunnel -> 0.6m interior (prone only), steps -> stairs test.
	var post_m: Material = mat("course_post", Color(0.3, 0.3, 0.34))
	var red_m: Material = mat("course_red", Color(0.75, 0.2, 0.18))
	var yel_m: Material = mat("course_yel", Color(0.85, 0.7, 0.2))
	var con_m: Material = mat("course_con", Color(0.55, 0.55, 0.58))
	# prone fence at z=44 (gap 0.0..0.6)
	for x in range(-12, 13, 3):
		_solid_box(parent, Vector3(x, 0.55, 44), Vector3(0.25, 1.1, 0.25), post_m)
	_solid_box(parent, Vector3(0, 0.875, 44), Vector3(24.5, 0.55, 0.3), red_m)
	# crouch gate at z=48 (gap 0.0..1.2)
	for x in range(-12, 13, 3):
		_solid_box(parent, Vector3(x, 0.85, 48), Vector3(0.25, 1.7, 0.25), post_m)
	_solid_box(parent, Vector3(0, 1.45, 48), Vector3(24.5, 0.5, 0.3), yel_m)
	# tunnel at x=-6, z 50..56 (interior height 0.6, width 2.0)
	_solid_box(parent, Vector3(-7.2, 0.6, 53), Vector3(0.4, 1.2, 6.4), con_m)
	_solid_box(parent, Vector3(-4.8, 0.6, 53), Vector3(0.4, 1.2, 6.4), con_m)
	_solid_box(parent, Vector3(-6.0, 0.75, 53), Vector3(2.8, 0.3, 6.4), con_m)
	# stairs at x=8..11, z=52 (5 x 0.2m steps + deck). The steps are VISUAL
	# ONLY: CharacterBody3D has no auto-step, so 0.2m boxes are walls
	# (floor_snap only grips downward). One invisible smooth ramp carries
	# the collision; the deck at the top stays solid.
	for i in 5:
		var h := 0.2 * float(i + 1)
		_deco_box(parent, Vector3(8.0 + float(i) * 0.4, h * 0.5, 52), Vector3(0.4, h, 2.0), con_m)
	_solid_box(parent, Vector3(10.6, 0.5, 52), Vector3(1.2, 1.0, 2.0), con_m)
	_stair_ramp(parent, Vector3(8.8, 0.42, 52), Vector3(2.7, 0.3, 2.2), 0.40)

## Invisible sloped collision for stair visuals. angle_z rises toward +X.
static func _stair_ramp(parent: Node3D, center: Vector3, size: Vector3, angle_z: float) -> void:
	var ramp := StaticBody3D.new()
	ramp.collision_layer = ArenaConfig.mask_world()
	ramp.collision_mask = 0
	ramp.position = center
	ramp.rotation.z = angle_z
	parent.add_child(ramp)
	var col := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	col.shape = bs
	ramp.add_child(col)

static func _ramps(parent: Node3D, m: Material) -> void:
	for zdir in [1.0, -1.0]:
		var ramp := StaticBody3D.new()
		ramp.collision_layer = ArenaConfig.mask_world()
		ramp.collision_mask = 0
		ramp.position = Vector3(0, 0.5, zdir * 11.5)
		# high end toward the plaza (z=9 edge, 1m top), low end buried
		# in the ground: walking in climbs smoothly onto the plaza
		ramp.rotation.x = zdir * 0.18
		parent.add_child(ramp)
		var col := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = Vector3(4.0, 0.3, 6.0)
		col.shape = bs
		ramp.add_child(col)
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(4.0, 0.3, 6.0)
		bm.material = m
		mi.mesh = bm
		ramp.add_child(mi)

static func _compound(parent: Node3D, center: Vector3, rot: float, covers: Array) -> void:
	var wall_m: Material = mat("compound", Color(0.62, 0.55, 0.45))
	var roof_m: Material = mat("roof", Color(0.35, 0.3, 0.26))
	var pivot := Node3D.new()
	pivot.position = center
	pivot.rotation.y = rot
	parent.add_child(pivot)
	# U-shape: back + 2 sides, front open (door gap), windows via split walls
	_solid_box(pivot, Vector3(0, 1.5, -4), Vector3(9, 3, 0.6), wall_m)
	_solid_box(pivot, Vector3(-4.2, 1.5, 0), Vector3(0.6, 3, 8.6), wall_m)
	_solid_box(pivot, Vector3(4.2, 1.5, 0), Vector3(0.6, 3, 8.6), wall_m)
	# roof slab on top (elevated position reachable via crate stack)
	_solid_box(pivot, Vector3(0, 3.4, -1), Vector3(9.5, 0.35, 7.5), roof_m)
	# crates as stairs to roof
	var crate_m: Material = mat("crate", Color(0.6, 0.45, 0.28))
	_solid_box(pivot, Vector3(6.5, 0.6, 3.5), Vector3(1.2, 1.2, 1.2), crate_m)
	_solid_box(pivot, Vector3(6.5, 1.5, 3.5), Vector3(1.0, 1.0, 1.0), crate_m)
	# interior divider (cover)
	_solid_box(pivot, Vector3(0, 0.8, 0.5), Vector3(3.2, 1.6, 0.5), wall_m, 0.2)
	var world_c := center + Vector3(2, 0, 2).rotated(Vector3.UP, rot)
	covers.append(world_c)

static func _warehouse(parent: Node3D, center: Vector3, rot: float, covers: Array) -> void:
	var wall_m: Material = mat("ware", Color(0.4, 0.5, 0.6))
	var roof_m: Material = mat("roof", Color(0.3, 0.32, 0.36))
	var pivot := Node3D.new()
	pivot.position = center
	pivot.rotation.y = rot
	parent.add_child(pivot)
	_solid_box(pivot, Vector3(0, 2, -5), Vector3(14, 4, 0.6), wall_m)
	_solid_box(pivot, Vector3(-6.7, 2, 0), Vector3(0.6, 4, 10.6), wall_m)
	_solid_box(pivot, Vector3(6.7, 2, 0), Vector3(0.6, 4, 10.6), wall_m)
	_solid_box(pivot, Vector3(0, 4.3, 0), Vector3(14.5, 0.4, 11), roof_m)
	# front posts (open front, long sightline in/out)
	_solid_box(pivot, Vector3(-6.7, 2, 5), Vector3(0.6, 4, 0.6), wall_m)
	_solid_box(pivot, Vector3(6.7, 2, 5), Vector3(0.6, 4, 0.6), wall_m)
	# interior stock
	var crate_m: Material = mat("crate", Color(0.6, 0.45, 0.28))
	_solid_box(pivot, Vector3(-3, 0.6, -2), Vector3(1.2, 1.2, 1.2), crate_m, 0.2, "wood")
	_solid_box(pivot, Vector3(3, 0.6, -1), Vector3(1.2, 1.2, 1.2), crate_m, -0.3, "wood")
	covers.append(center + Vector3(3, 0, 4).rotated(Vector3.UP, rot))

static func _containers(parent: Node3D, covers: Array) -> void:
	var cols := [Color(0.7, 0.25, 0.2), Color(0.2, 0.45, 0.7), Color(0.3, 0.6, 0.3), Color(0.7, 0.55, 0.2)]
	var spots := [Vector3(10, 0, 22), Vector3(-10, 0, -22), Vector3(14, 0, -14),
		Vector3(-14, 0, 14), Vector3(0, 0, 30), Vector3(0, 0, -30),
		Vector3(22, 0, -4), Vector3(-22, 0, 4)]
	var i := 0
	for sp in spots:
		sp = (sp as Vector3) + Vector3(randf_range(-2.0, 2.0), 0, randf_range(-2.0, 2.0))
		var cm: Material = mat("cont%d" % (i % 4), cols[i % 4], 0.7)
		_solid_box(parent, sp + Vector3(0, 1.3, 0), Vector3(6.0, 2.6, 2.4), cm, randf() * 0.5, "metal")
		if i % 3 == 0:
			_solid_box(parent, sp + Vector3(0, 3.9, 0), Vector3(6.0, 2.6, 2.4), cm, randf() * 0.5, "metal")
		covers.append(sp + Vector3(3.5, 0, 0))
		i += 1

static func _bridge(parent: Node3D, covers: Array) -> void:
	var deck_m: Material = mat("deck", Color(0.4, 0.36, 0.32))
	var rail_m: Material = mat("rail", Color(0.25, 0.28, 0.32))
	# deck spanning x -18..18 at z = -12, height 4
	_solid_box(parent, Vector3(0, 3.8, -12), Vector3(36, 0.4, 3.2), deck_m, 0.0, "metal")
	_solid_box(parent, Vector3(0, 4.6, -13.4), Vector3(36, 0.9, 0.25), rail_m, 0.0, "metal")
	_solid_box(parent, Vector3(0, 4.6, -10.6), Vector3(36, 0.9, 0.25), rail_m, 0.0, "metal")
	# support pillars
	for x in [-15.0, -5.0, 5.0, 15.0]:
		_solid_box(parent, Vector3(x, 1.9, -12), Vector3(0.8, 3.8, 0.8), rail_m)
	# access ramps both ends: low foot on the ground (x=±28) rising to the
	# deck edge (x=±18, 4m top). ~22° slope, walkable both ways
	for xdir in [1.0, -1.0]:
		var ramp := StaticBody3D.new()
		ramp.collision_layer = ArenaConfig.mask_world()
		ramp.collision_mask = 0
		ramp.position = Vector3(xdir * 23.0, 2.0, -12)
		ramp.rotation.z = -xdir * 0.38
		parent.add_child(ramp)
		var col := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = Vector3(10.8, 0.3, 3.0)
		col.shape = bs
		ramp.add_child(col)
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(10.8, 0.3, 3.0)
		bm.material = deck_m
		mi.mesh = bm
		ramp.add_child(mi)
	covers.append(Vector3(0, 4.0, -12))

static func _trees(parent: Node3D) -> void:
	var trunk_m: Material = mat("trunk", Color(0.35, 0.25, 0.16))
	var leaf := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = "shader_type spatial; render_mode cull_disabled;\nuniform vec4 col : source_color = vec4(0.2,0.45,0.22,1.0);\nuniform float sway = 0.12;\nvoid vertex() { VERTEX.x += sin(TIME*1.6 + (MODEL_MATRIX[3][0]+MODEL_MATRIX[3][2])*0.5) * sway * VERTEX.y; }\nvoid fragment() { ALBEDO = col.rgb; ROUGHNESS = 0.9; }"
	leaf.shader = sh
	for i in 26:
		var a := TAU * i / 26.0 + randf_range(-0.1, 0.1)
		var r := RADIUS - randf_range(2.0, 8.0) if i % 4 != 0 else RADIUS * randf_range(0.55, 0.8)
		var p := Vector3(cos(a) * r, 0, sin(a) * r)
		if absf(p.x) < 12.0 and absf(p.z) < 12.0:
			continue # keep hotspot readable
		if absf(p.x) < 18.0 and p.z > 38.0 and p.z < 58.0:
			continue # keep movement course clear
		var tree := StaticBody3D.new()
		tree.collision_layer = ArenaConfig.mask_world()
		tree.collision_mask = 0
		tree.position = p
		tree.add_to_group("surf_wood")
		parent.add_child(tree)
		var tc := CollisionShape3D.new()
		var cyl := CylinderShape3D.new()
		cyl.radius = 0.3
		cyl.height = 2.6
		tc.shape = cyl
		tc.position = Vector3(0, 1.3, 0)
		tree.add_child(tc)
		var trunk := MeshInstance3D.new()
		var tm := CylinderMesh.new()
		tm.top_radius = 0.18
		tm.bottom_radius = 0.3
		tm.height = 2.6
		tm.radial_segments = 6
		tm.material = trunk_m
		trunk.mesh = tm
		trunk.position = Vector3(0, 1.3, 0)
		tree.add_child(trunk)
		for k in 2:
			var can := MeshInstance3D.new()
			var sm := SphereMesh.new()
			sm.radius = 1.5 - k * 0.4
			sm.height = 2.0 - k * 0.4
			sm.radial_segments = 7
			sm.rings = 4
			sm.material = leaf
			can.mesh = sm
			can.position = Vector3(0, 3.0 + k * 1.1, 0)
			tree.add_child(can)

static func _grass(parent: Node3D) -> void:
	# one MultiMesh draw call: 700 wind-swayed tufts
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = false
	var qm := QuadMesh.new()
	qm.size = Vector2(0.34, 0.4)
	var smat := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = "shader_type spatial; render_mode cull_disabled;\nuniform vec4 col : source_color = vec4(0.42,0.56,0.28,1.0);\nvoid vertex() { VERTEX.x += sin(TIME*2.2 + INSTANCE_CUSTOM.x*17.0) * 0.06 * UV.y; }\nvoid fragment() { ALBEDO = col.rgb; }"
	smat.shader = sh
	qm.material = smat
	mm.mesh = qm
	mm.instance_count = 700
	for i in 700:
		var a := randf() * TAU
		var r := sqrt(randf()) * (RADIUS - 2.0)
		var t := Transform3D(Basis(Vector3.UP, randf() * TAU), Vector3(cos(a) * r, 0.2, sin(a) * r))
		mm.set_instance_transform(i, t)
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mmi)

static func _lamps(parent: Node3D) -> void:
	var pole_m: Material = mat("pole", Color(0.15, 0.16, 0.18))
	var glow_m: Material = mat("lampglow", Color(1.0, 0.9, 0.7), 0.5, Color(1.0, 0.85, 0.6))
	for lp in [Vector3(8, 0, 8), Vector3(-8, 0, -8), Vector3(8, 0, -8), Vector3(-8, 0, 8)]:
		_solid_box(parent, lp + Vector3(0, 2.5, 0), Vector3(0.25, 5.0, 0.25), pole_m)
		_deco_box(parent, lp + Vector3(0, 5.1, 0), Vector3(0.7, 0.3, 0.7), glow_m)
