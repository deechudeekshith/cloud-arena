class_name WeaponViewBuilder
extends RefCounted

## Original low-poly weapon models (no floating cubes): receiver, barrel,
## stock, grip, magazine, sights. Shared BoxMesh cache, per-skin materials.

static var _mesh_cache := {}
static var _mat_cache := {}

static func _bm(sx: float, sy: float, sz: float) -> BoxMesh:
	var k := "w_%0.2f_%0.2f_%0.2f" % [sx, sy, sz]
	if _mesh_cache.has(k):
		return _mesh_cache[k]
	var m := BoxMesh.new()
	m.size = Vector3(sx, sy, sz)
	_mesh_cache[k] = m
	return m

static func _mt(c: Color, e: Color) -> StandardMaterial3D:
	var k := "%s_%s" % [c.to_html(), e.to_html()]
	if _mat_cache.has(k):
		return _mat_cache[k]
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.55
	m.metallic = 0.35
	if e != Color(0, 0, 0):
		m.emission_enabled = true
		m.emission = e
		m.emission_energy_multiplier = 1.2
	_mat_cache[k] = m
	return m

static func _box(parent: Node3D, pos: Vector3, size: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = _bm(size.x, size.y, size.z)
	mi.material_override = mat
	mi.position = pos
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return mi

## First-person viewmodel. Origin at camera; gun extends -Z.
## Includes view arms/hands + muzzle light (FP only).
static func build_viewmodel(weapon_id: int, skin_id: int = 0) -> Node3D:
	var root := _build_gun(weapon_id, skin_id, true)
	root.name = "WeaponView"
	return root

## Third-person gun. Gun-only (no arms), extends -Z (character forward).
## Mount with HumanoidBuilder.attach_weapon_to_hand() so it follows the
## arm animation. Has Muzzle / EjectPort markers + flash quad (no light).
static func build_worldmodel(weapon_id: int, skin_id: int = 0) -> Node3D:
	var vm := _build_gun(weapon_id, skin_id, false)
	vm.name = "WeaponWorld"
	return vm

static func _build_gun(weapon_id: int, skin_id: int, fp: bool) -> Node3D:
	var w := WeaponDB.get_weapon(weapon_id)
	var sk := WeaponDB.get_skin(skin_id)
	var base: Color = w["color"]
	var tint: Color = sk["tint"]
	var emis: Color = sk["emissive"]
	var body := _mt(base * tint * 1.5 + Color(0.03, 0.03, 0.03), emis)
	var dark := _mt(Color(0.07, 0.075, 0.09), Color(0, 0, 0))
	var grip_m := _mt(Color(0.12, 0.1, 0.09), Color(0, 0, 0))
	var root := Node3D.new()
	root.name = "WeaponView"
	var L: float = float(w["length"])
	# receiver
	_box(root, Vector3(0, 0, -L * 0.45), Vector3(0.09, 0.13, L * 0.55), body)
	# barrel + shroud
	_box(root, Vector3(0, 0.015, -L * 0.95), Vector3(0.05, 0.06, L * 0.4), dark)
	# front sight
	_box(root, Vector3(0, 0.075, -L * 1.05), Vector3(0.02, 0.05, 0.03), dark)
	# rear sight ring
	_box(root, Vector3(0, 0.085, -L * 0.25), Vector3(0.04, 0.04, 0.06), dark)
	# stock
	_box(root, Vector3(0, -0.03, L * 0.02), Vector3(0.08, 0.12, 0.22), grip_m)
	# grip
	var grip := _box(root, Vector3(0, -0.13, -L * 0.22), Vector3(0.07, 0.16, 0.08), grip_m)
	grip.rotation.x = 0.3
	# magazine
	var mag := _box(root, Vector3(0, -0.13, -L * 0.45), Vector3(0.07, 0.18, 0.1), dark)
	mag.rotation.x = -0.15
	if int(w["id"]) == 2: # shotgun: pump + thick tube
		_box(root, Vector3(0, -0.05, -L * 0.8), Vector3(0.07, 0.07, 0.25), grip_m)
		_box(root, Vector3(0, 0.05, -L * 0.95), Vector3(0.06, 0.06, L * 0.45), body)
	if int(w["id"]) == 1: # smg: short + suppressor + side mag
		_box(root, Vector3(0, 0.015, -L * 1.1), Vector3(0.055, 0.055, 0.22), dark)
	# skin accent strip
	if emis != Color(0, 0, 0):
		_box(root, Vector3(0, 0.045, -L * 0.45), Vector3(0.095, 0.015, L * 0.4), _mt(emis, emis))
	# view arms (FP only: sleeves + hands so gun isn't floating)
	if fp:
		var skin_m := _mt(Color(0.85, 0.62, 0.47), Color(0, 0, 0))
		var sleeve := _mt(Color(0.16, 0.2, 0.28), Color(0, 0, 0))
		_box(root, Vector3(0.02, -0.16, -L * 0.2), Vector3(0.09, 0.09, 0.3), sleeve)
		_box(root, Vector3(0.0, -0.1, -L * 0.42), Vector3(0.08, 0.08, 0.12), skin_m)
		_box(root, Vector3(0.12, -0.2, 0.05), Vector3(0.09, 0.09, 0.28), sleeve)
	var muzzle := Node3D.new()
	muzzle.name = "Muzzle"
	muzzle.position = Vector3(0, 0.015, -L * 1.15)
	root.add_child(muzzle)
	# shell eject marker (right side of receiver)
	var eject := Node3D.new()
	eject.name = "EjectPort"
	eject.position = Vector3(0.05, 0.03, -L * 0.3)
	root.add_child(eject)
	# flash light (FP only; TP uses the quad to save lights)
	if fp:
		var flash := OmniLight3D.new()
		flash.name = "MuzzleFlash"
		flash.light_color = Color(1.0, 0.75, 0.4)
		flash.light_energy = 0.0
		flash.omni_range = 6.0
		flash.position = muzzle.position
		root.add_child(flash)
	var quad := MeshInstance3D.new()
	quad.name = "FlashQuad"
	var qm := QuadMesh.new()
	qm.size = Vector2(0.22, 0.22)
	quad.mesh = qm
	var qmat := StandardMaterial3D.new()
	qmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	qmat.albedo_color = Color(1, 0.8, 0.4, 0.9)
	qmat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	qmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	quad.material_override = qmat
	quad.visible = false
	quad.position = muzzle.position
	root.add_child(quad)
	return root
