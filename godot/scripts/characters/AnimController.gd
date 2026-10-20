class_name AnimController
extends RefCounted

## Procedural pose driver for HumanoidBuilder rigs.
## Reacts to real velocity (no foot sliding: swing freq scales with speed).
## Facing = local -Z (muzzle/arms side). Face/visor = local +Z... see note.
## NOTE: rig front (movement, muzzle, arms) is local -Z.
## States: STANDING/RUNNING/SPRINTING/CROUCHING/PRONE/CRAWLING/JUMP/FALL.

const ST_STANDING := "STANDING"
const ST_RUNNING := "RUNNING"
const ST_SPRINTING := "SPRINTING"
const ST_CROUCHING := "CROUCHING"
const ST_PRONE := "PRONE"
const ST_CRAWLING := "CRAWLING"
const ST_JUMP := "JUMP"
const ST_FALL := "FALL"

static func anim_state_for(speed: float, airborne: bool, vy: float,
		sprinting: bool, crouching: bool, prone: bool) -> String:
	if airborne:
		return ST_JUMP if vy > 0.5 else ST_FALL
	if prone:
		return ST_CRAWLING if speed > 0.2 else ST_PRONE
	if crouching:
		return ST_CROUCHING
	if speed < 0.4:
		return ST_STANDING
	if sprinting and speed > 5.0:
		return ST_SPRINTING
	if speed > 2.5:
		return ST_RUNNING
	return ST_STANDING

static func pose(parts: Dictionary, root: Node3D, dt: float, s: Dictionary) -> void:
	# s: {time, speed, airborne, vy, sprinting, crouch, prone, prone_blend,
	#     firing, reload_t(-1 off), hit_t, dead, death_t, aim_pitch, spawn_t}
	var t: float = float(s.get("time", 0.0))
	var speed: float = float(s.get("speed", 0.0))
	var dead: bool = bool(s.get("dead", false))
	var death_t: float = float(s.get("death_t", 0.0))
	if dead:
		_pose_dead(parts, root, death_t)
		return

	var crouch: bool = bool(s.get("crouch", false))
	var prone: bool = bool(s.get("prone", false))
	var airborne: bool = bool(s.get("airborne", false))
	var firing: bool = bool(s.get("firing", false))
	var reload_t: float = float(s.get("reload_t", -1.0))
	var hit_t: float = float(s.get("hit_t", 99.0))
	var aim_pitch: float = clamp(float(s.get("aim_pitch", 0.0)), -1.5, 1.5)

	var hips: Node3D = parts["Hips"]
	var torso: Node3D = parts["Torso"]
	var head: Node3D = parts["Head"]

	# stand<->prone blend weight (0 upright .. 1 flat), smoothed by caller
	var pb: float = clampf(float(s.get("prone_blend", 1.0 if prone else 0.0)), 0.0, 1.0)

	var flinch := 0.0
	if hit_t < 0.25:
		flinch = (1.0 - hit_t / 0.25) * 0.35

	# root stays upright in all stances (prone is built from joints below)
	root.rotation.x = 0.0
	root.rotation.z = 0.0
	root.position.y = 0.0
	hips.position.y = (0.62 if crouch else 0.96)

	# ---- legs ----
	if airborne:
		parts["LegL_U"].rotation.x = -0.5
		parts["LegL_L"].rotation.x = 0.7
		parts["LegR_U"].rotation.x = 0.25
		parts["LegR_L"].rotation.x = 0.4
	else:
		var freq := 4.0 + speed * 1.8
		var amp: float = clamp(speed / 7.0, 0.0, 1.0) * (0.55 if not crouch else 0.35)
		var sw := sin(t * freq)
		var sw2 := sin(t * freq + PI)
		parts["LegL_U"].rotation.x = sw * amp
		parts["LegL_L"].rotation.x = max(0.0, -sw2 * amp * 1.2)
		parts["LegR_U"].rotation.x = sw2 * amp
		parts["LegR_L"].rotation.x = max(0.0, -sw * amp * 1.2)

	# ---- torso ----
	torso.rotation.x = clamp(speed * 0.03, 0.0, 0.22) + (0.12 if crouch else 0.0) + flinch * 0.6
	torso.rotation.y = 0.0
	torso.rotation.z = 0.0
	if not airborne and speed < 0.4:
		torso.position.y = 0.12 + sin(t * 2.0) * 0.008

	# ---- arms ----
	if reload_t >= 0.0:
		var rk := sin(reload_t * PI)
		parts["ArmL_U"].rotation.x = -1.1 - rk * 0.4
		parts["ArmR_U"].rotation.x = -1.1 + rk * 0.3
		parts["ArmL_L"].rotation.x = -0.5
		parts["ArmR_L"].rotation.x = -0.5
	elif firing or speed > 0.5:
		parts["ArmR_U"].rotation.x = -1.25 + aim_pitch * 0.5
		parts["ArmL_U"].rotation.x = -1.15 + aim_pitch * 0.5
		parts["ArmR_L"].rotation.x = -0.35
		parts["ArmL_L"].rotation.x = -0.45
		if speed > 0.5:
			var sw3 := sin(t * (4.0 + speed * 1.8))
			parts["ArmR_U"].rotation.x += sw3 * 0.08
			parts["ArmL_U"].rotation.x += cos(t * (4.0 + speed * 1.8)) * 0.08
	else:
		var sw := sin(t * (4.0 + speed * 1.8))
		var sw2 := sin(t * (4.0 + speed * 1.8) + PI)
		var amp: float = clamp(speed / 7.0, 0.0, 1.0) * 0.7
		parts["ArmL_U"].rotation.x = sw2 * amp
		parts["ArmR_U"].rotation.x = sw * amp
		parts["ArmL_L"].rotation.x = -0.15
		parts["ArmR_L"].rotation.x = -0.15

	# ---- head look ----
	head.rotation.x = aim_pitch * 0.35
	head.rotation.y = 0.0

	# recoil kick on torso when firing upright
	if firing and not prone:
		torso.rotation.x += 0.03

	# ---- prone overlay: tactical flat pose, lerped by pb ----
	# hips drop, torso tips forward, head counters to face ahead-down,
	# arms reach to the ground, legs trail back. Crawl adds limb stride.
	if pb > 0.001:
		var crawling := speed > 0.3
		var stride := sin(t * 3.2) if crawling else 0.0
		hips.position.y = lerpf(hips.position.y, 0.32, pb)
		torso.rotation.x = lerpf(torso.rotation.x, 1.2, pb)
		torso.rotation.y = lerpf(torso.rotation.y, 0.0, pb)
		torso.rotation.z = lerpf(torso.rotation.z, 0.0, pb)
		head.rotation.x = lerpf(head.rotation.x, -1.0, pb)
		head.rotation.y = lerpf(head.rotation.y, 0.0, pb)
		parts["ArmL_U"].rotation.x = lerpf(parts["ArmL_U"].rotation.x, -1.5 - stride * 0.2, pb)
		parts["ArmR_U"].rotation.x = lerpf(parts["ArmR_U"].rotation.x, -1.5 + stride * 0.2, pb)
		parts["ArmL_L"].rotation.x = lerpf(parts["ArmL_L"].rotation.x, -0.5, pb)
		parts["ArmR_L"].rotation.x = lerpf(parts["ArmR_L"].rotation.x, -0.5, pb)
		parts["LegL_U"].rotation.x = lerpf(parts["LegL_U"].rotation.x, -1.5 + stride * 0.3, pb)
		parts["LegR_U"].rotation.x = lerpf(parts["LegR_U"].rotation.x, -1.5 - stride * 0.3, pb)
		parts["LegL_L"].rotation.x = lerpf(parts["LegL_L"].rotation.x, -0.25, pb)
		parts["LegR_L"].rotation.x = lerpf(parts["LegR_L"].rotation.x, -0.25, pb)

static func _pose_dead(parts: Dictionary, root: Node3D, death_t: float) -> void:
	var k: float = clamp(death_t / 0.5, 0.0, 1.0)
	# fall forward, face down (rig front is local -Z)
	root.rotation.x = -PI * 0.5 * ease(k, 2.0)
	root.position.y = lerpf(0.0, 0.15, k)
	for key in ["ArmL_U", "ArmR_U", "LegL_U", "LegR_U"]:
		parts[key].rotation.z = -0.3 * k
