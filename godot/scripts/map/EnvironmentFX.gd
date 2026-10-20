class_name EnvironmentFX
extends RefCounted

## Ambient life: drifting dust motes + waving team banners + smoke columns.
## All shader/CPU-cheap, shared resources.

static func dust(parent: Node3D) -> void:
	var p := CPUParticles3D.new()
	p.name = "DustMotes"
	p.amount = 60
	p.lifetime = 6.0
	p.preprocess = 6.0
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	p.emission_box_extents = Vector3(55, 3, 55)
	p.direction = Vector3(1, 0.15, 0.3)
	p.spread = 20.0
	p.initial_velocity_min = 0.4
	p.initial_velocity_max = 1.2
	p.gravity = Vector3.ZERO
	p.scale_amount_min = 0.05
	p.scale_amount_max = 0.14
	p.color = Color(1.0, 0.95, 0.8, 0.35)
	p.position = Vector3(0, 3, 0)
	parent.add_child(p)
	# two smoke columns (burning barrels near compounds)
	for sp in [Vector3(24, 0, 34), Vector3(-24, 0, -34)]:
		var barrel := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.4
		cm.bottom_radius = 0.4
		cm.height = 1.0
		var bm := StandardMaterial3D.new()
		bm.albedo_color = Color(0.2, 0.2, 0.22)
		cm.material = bm
		barrel.mesh = cm
		barrel.position = sp + Vector3(0, 0.5, 0)
		parent.add_child(barrel)
		var s := CPUParticles3D.new()
		s.amount = 24
		s.lifetime = 3.0
		s.preprocess = 3.0
		s.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
		s.emission_sphere_radius = 0.3
		s.direction = Vector3(0, 1, 0)
		s.spread = 12.0
		s.initial_velocity_min = 1.0
		s.initial_velocity_max = 2.0
		s.gravity = Vector3(0, 0.6, 0)
		s.scale_amount_min = 0.4
		s.scale_amount_max = 1.0
		s.color = Color(0.25, 0.25, 0.28, 0.5)
		s.position = sp + Vector3(0, 1.2, 0)
		parent.add_child(s)

static func banners(parent: Node3D) -> void:
	var sh := Shader.new()
	sh.code = "shader_type spatial; render_mode cull_disabled;\nuniform vec4 col : source_color = vec4(0.2,0.5,1.0,1.0);\nvoid vertex() { float w = (1.0-UV.x); VERTEX.z += sin(TIME*3.0 + VERTEX.x*2.0) * 0.25 * w; }\nvoid fragment() { ALBEDO = col.rgb; }"
	for i in 4:
		var a := TAU * i / 4.0 + PI * 0.25
		var p := Vector3(cos(a) * 12.0, 0, sin(a) * 12.0)
		var pole := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.08
		cm.bottom_radius = 0.08
		cm.height = 6.0
		var pm := StandardMaterial3D.new()
		pm.albedo_color = Color(0.15, 0.16, 0.18)
		cm.material = pm
		pole.mesh = cm
		pole.position = p + Vector3(0, 3, 0)
		parent.add_child(pole)
		var flag := MeshInstance3D.new()
		var qm := QuadMesh.new()
		qm.size = Vector2(1.8, 1.0)
		var fmat := ShaderMaterial.new()
		fmat.shader = sh
		fmat.set_shader_parameter("col", Vector4(0.2, 0.5, 1.0, 1.0) if i % 2 == 0 else Vector4(1.0, 0.3, 0.25, 1.0))
		qm.material = fmat
		flag.mesh = qm
		flag.position = p + Vector3(0.95, 5.3, 0)
		parent.add_child(flag)
