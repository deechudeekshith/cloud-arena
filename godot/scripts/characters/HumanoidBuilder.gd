class_name HumanoidBuilder
extends RefCounted

## Procedural low-poly humanoid. Original design, no external assets.
## Shared skeleton interface so GLB characters can replace the meshes
## later without touching gameplay code:
##   root (Node3D "Humanoid")
##     Hips -> Torso -> Head, ArmL_U -> ArmL_L, ArmR_U -> ArmR_L
##     Hips -> LegL_U -> LegL_L, LegR_U -> LegR_L
## AnimController poses these pivots by name.
## Head carries an Area3D "HeadHitbox" (layer L_HEAD) for headshots.

static var _box_cache := {}
static var _mat_cache := {}

static func _box(sx: float, sy: float, sz: float) -> BoxMesh:
	var k := "%0.2f_%0.2f_%0.2f" % [sx, sy, sz]
	if _box_cache.has(k):
		return _box_cache[k]
	var m := BoxMesh.new()
	m.size = Vector3(sx, sy, sz)
	m.material = null
	_box_cache[k] = m
	return m

static func _mat(c: Color, emissive := false) -> StandardMaterial3D:
	var k := "%s_%d" % [c.to_html(), int(emissive)]
	if _mat_cache.has(k):
		return _mat_cache[k]
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.85
	m.metallic = 0.0
	if emissive:
		m.emission_enabled = true
		m.emission = c
		m.emission_energy_multiplier = 0.7
	_mat_cache[k] = m
	return m

static func _part(parent: Node3D, pname: String, pos: Vector3, size: Vector3, color: Color) -> Node3D:
	var pivot := Node3D.new()
	pivot.name = pname
	pivot.position = pos
	parent.add_child(pivot)
	var mi := MeshInstance3D.new()
	mi.name = pname + "_Mesh"
	mi.mesh = _box(size.x, size.y, size.z)
	mi.material_override = _mat(color)
	# mesh centered on pivot's child offset so rotation pivots at joint
	pivot.add_child(mi)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	return pivot

static func _offset_mesh(pivot: Node3D, off: Vector3) -> void:
	var mi: MeshInstance3D = pivot.get_node(str(pivot.name) + "_Mesh")
	mi.position = off

## Build a full third-person body. Returns {"root": Node3D, "parts": {...}}.
static func build(avatar: Dictionary, team_id: int = 0) -> Dictionary:
	var bulk: float = float(avatar.get("bulk", 1.0))
	var hscale: float = float(avatar.get("height", 1.8)) / 1.8
	var jacket: Color = avatar["jacket"]
	var pants: Color = avatar["pants"]
	var skin: Color = avatar["skin"]
	var vest: Color = avatar["vest"]
	var boots: Color = avatar["boots"]
	var accent: Color = avatar["accent"]
	var team_col: Color = ArenaConfig.TEAM_COLORS[team_id % 2]

	var root := Node3D.new()
	root.name = "Humanoid"
	# Collision capsule is owned by CharacterBody, this visual is offset so feet = y0.
	var parts := {}

	var hips: Node3D = _part(root, "Hips", Vector3(0, 0.96 * hscale, 0), Vector3(0.34 * bulk, 0.18, 0.22), pants)
	parts["Hips"] = hips
	var torso: Node3D = _part(hips, "Torso", Vector3(0, 0.12, 0), Vector3(0.4 * bulk, 0.52, 0.26), jacket)
	parts["Torso"] = torso
	_offset_mesh(torso, Vector3(0, 0.3, 0))
	# vest plate
	var vest_mi := MeshInstance3D.new()
	vest_mi.name = "VestMesh"
	vest_mi.mesh = _box(0.42 * bulk, 0.3, 0.29)
	vest_mi.material_override = _mat(vest)
	vest_mi.position = Vector3(0, 0.32, 0)
	torso.add_child(vest_mi)
	# team stripe (shoulder bar) — gameplay-critical team ID
	var stripe := MeshInstance3D.new()
	stripe.name = "TeamStripe"
	stripe.mesh = _box(0.44 * bulk, 0.07, 0.3)
	stripe.material_override = _mat(team_col, true)
	stripe.position = Vector3(0, 0.52, 0)
	torso.add_child(stripe)
	# head
	var head: Node3D = _part(torso, "Head", Vector3(0, 0.62, 0), Vector3(0.24, 0.26, 0.24), skin)
	parts["Head"] = head
	_offset_mesh(head, Vector3(0, 0.14, 0))
	# accessory
	_add_accessory(head, str(avatar.get("accessory", "")), accent, bulk)
	# arms (pivot at shoulder)
	var aL: Node3D = _part(torso, "ArmL_U", Vector3(-0.27 * bulk, 0.5, 0), Vector3(0.11, 0.34, 0.12), jacket)
	parts["ArmL_U"] = aL
	_offset_mesh(aL, Vector3(0, -0.16, 0))
	var aLl: Node3D = _part(aL, "ArmL_L", Vector3(0, -0.34, 0), Vector3(0.1, 0.3, 0.11), skin)
	parts["ArmL_L"] = aLl
	_offset_mesh(aLl, Vector3(0, -0.14, 0))
	var aR: Node3D = _part(torso, "ArmR_U", Vector3(0.27 * bulk, 0.5, 0), Vector3(0.11, 0.34, 0.12), jacket)
	parts["ArmR_U"] = aR
	_offset_mesh(aR, Vector3(0, -0.16, 0))
	var aRl: Node3D = _part(aR, "ArmR_L", Vector3(0, -0.34, 0), Vector3(0.1, 0.3, 0.11), skin)
	parts["ArmR_L"] = aRl
	_offset_mesh(aRl, Vector3(0, -0.14, 0))
	# gun grip hint in right hand (third-person weapon added separately)
	# legs (pivot at hip)
	var lL: Node3D = _part(hips, "LegL_U", Vector3(-0.11, -0.06, 0), Vector3(0.14, 0.42, 0.15), pants)
	parts["LegL_U"] = lL
	_offset_mesh(lL, Vector3(0, -0.22, 0))
	var lLl: Node3D = _part(lL, "LegL_L", Vector3(0, -0.46, 0), Vector3(0.13, 0.42, 0.14), boots)
	parts["LegL_L"] = lLl
	_offset_mesh(lLl, Vector3(0, -0.2, 0))
	var lR: Node3D = _part(hips, "LegR_U", Vector3(0.11, -0.06, 0), Vector3(0.14, 0.42, 0.15), pants)
	parts["LegR_U"] = lR
	_offset_mesh(lR, Vector3(0, -0.22, 0))
	var lRl: Node3D = _part(lR, "LegR_L", Vector3(0, -0.46, 0), Vector3(0.13, 0.42, 0.14), boots)
	parts["LegR_L"] = lRl
	_offset_mesh(lRl, Vector3(0, -0.2, 0))

	# Head hitbox for headshot differentiation.
	var head_area := Area3D.new()
	head_area.name = "HeadHitbox"
	head_area.collision_layer = 1 << (ArenaConfig.L_HEAD - 1)
	head_area.collision_mask = 0
	head_area.monitoring = false
	head_area.monitorable = true
	head_area.add_to_group("head_hitbox")
	var col := CollisionShape3D.new()
	var sph := SphereShape3D.new()
	sph.radius = 0.19
	col.shape = sph
	head_area.add_child(col)
	head.add_child(head_area)
	head_area.position = Vector3(0, 0.14, 0)

	root.set_meta("anim_parts", parts.keys())
	return {"root": root, "parts": parts, "stripe": stripe}

static func _add_accessory(head: Node3D, kind: String, accent: Color, bulk: float) -> void:
	var mi := MeshInstance3D.new()
	match kind:
		"visor":
			mi.mesh = _box(0.26, 0.07, 0.05)
			mi.material_override = _mat(accent, true)
			mi.position = Vector3(0, 0.18, -0.13) # front (-Z is facing side)
			head.add_child(mi)
		"helmet":
			mi.mesh = _box(0.3, 0.14, 0.3)
			mi.material_override = _mat(Color(0.2, 0.22, 0.2))
			mi.position = Vector3(0, 0.28, 0)
			head.add_child(mi)
		"backpack":
			pass # backpack lives on torso; add small tank
			var pk := MeshInstance3D.new()
			pk.mesh = _box(0.26, 0.34, 0.12)
			pk.material_override = _mat(accent)
			pk.position = Vector3(0, 0.32, 0.2) # back (+Z), behind torso
			head.get_parent().add_child(pk)
		"hood":
			mi.mesh = _box(0.28, 0.3, 0.28)
			mi.material_override = _mat(Color(0.07, 0.08, 0.1))
			mi.position = Vector3(0, 0.16, -0.02)
			head.add_child(mi)
		_:
			pass

## Drop-in path for future GLB characters. Keeps gameplay code untouched:
## external model must expose the same pivot names; we reparent + map.
static func attach_external_model(body_root: Node3D, glb_path: String) -> Node3D:
	if not ResourceLoader.exists(glb_path):
		return null
	var packed: PackedScene = load(glb_path)
	if packed == null:
		return null
	var inst: Node3D = packed.instantiate()
	body_root.add_child(inst)
	return inst

## Mount a third-person gun into the right hand (end of right forearm).
## The gun inherits arm-pose animation, so it tracks aim/reload/death.
## Gun space: grip at origin, barrel extends -Z (character forward).
static func attach_weapon_to_hand(parts: Dictionary, gun: Node3D) -> void:
	var hand: Node3D = parts.get("ArmR_L")
	if hand == null:
		return
	gun.name = "WeaponWorld"
	hand.add_child(gun)
	# grip sits in the palm (end of forearm), barrel forward
	gun.position = Vector3(0, -0.30, -0.04)
	gun.rotation = Vector3.ZERO
