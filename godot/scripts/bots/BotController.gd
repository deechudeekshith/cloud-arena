class_name BotController
extends CharacterBody3D

## Bot combatant: CharacterBody3D + steering + state machine.
## IDLE PATROL SEARCH CHASE AIM ATTACK RELOAD TAKE_COVER RETREAT DEAD RESPAWN
## Shares combat/visual interface with PlayerController (apply_hit/snapshot).

signal health_changed(hp: float, max_hp: float)
signal died(player_id: int, killer_id: int)

enum B { IDLE, PATROL, SEARCH, CHASE, AIM, ATTACK, RELOAD, TAKE_COVER, RETREAT, DEAD }

var player_id := 0
var team_id := 1
var avatar_id := 1
var display_name := "Bot"
var skill := 0.6 # 0..1 reaction + accuracy scalar

var health: Health
var weapon: Weapon
var body_visual: Node3D
var body_parts := {}
var tp_gun: Node3D # third-person gun mounted in the right hand
var shot_audio: AudioStreamPlayer3D

var state: int = B.IDLE
var enemy: Node3D = null
var move_target := Vector3.ZERO
var has_move := false
var wander_t := 0.0
var react_t := 0.0
var burst_left := 0
var burst_pause := 0.0
var strafe_dir := 1.0
var strafe_t := 0.0
var stuck_t := 0.0
var last_pos := Vector3.ZERO
var dead := false

var query_enemies: Callable  # func(bot) -> Array[Node3D]
var damage_fn: Callable
var fx_parent: Node3D
var cover_points: Array = []
var home_pos := Vector3.ZERO
var combatants: Array = []

var _anim_t := 0.0
var _hit_t := 99.0
var _death_t := 0.0
var _spawn_t := 99.0
var _aim_pitch := 0.0
var _yaw := 0.0

# Abilities
var ability_state := {}
var _ability_timer := 0.0
var _was_cloaked := false
var speed_mod := 1.0
var health_mod := 1.0

func setup(p_id: int, p_team: int, p_avatar: int, p_name: String,
		qe: Callable, dmg: Callable, fx: Node3D, covers: Array, home: Vector3, p_skill: float) -> void:
	player_id = p_id
	team_id = p_team
	avatar_id = p_avatar
	display_name = p_name
	query_enemies = qe
	damage_fn = dmg
	fx_parent = fx
	cover_points = covers
	home_pos = home
	skill = p_skill
	move_target = home
	has_move = true

func _ready() -> void:
	add_to_group("combatant")
	add_to_group("team_%d" % team_id)
	collision_layer = ArenaConfig.mask_body()
	collision_mask = ArenaConfig.mask_world() | ArenaConfig.mask_body()
	floor_snap_length = 0.45
	floor_max_angle = deg_to_rad(50.0)
	var col := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.38
	cap.height = 1.8
	col.shape = cap
	col.position = Vector3(0, 0.9, 0)
	add_child(col)
	health = Health.new()
	health.max_hp = ArenaConfig.MAX_HP
	add_child(health)
	health.damaged.connect(func(_a: float, _f: int, _h: bool) -> void: health_changed.emit(health.hp, health.max_hp))
	health.died.connect(_on_died)
	var wid: int = [0, 1, 2][player_id % 3]
	weapon = Weapon.create(wid)
	add_child(weapon)
	weapon.set_self_exceptions([get_rid()])
	var built: Dictionary = HumanoidBuilder.build(AvatarDB.get_preset(avatar_id), team_id)
	body_visual = built["root"]
	body_parts = built["parts"]
	add_child(body_visual)
	tp_gun = WeaponViewBuilder.build_worldmodel(wid, player_id % 3)
	HumanoidBuilder.attach_weapon_to_hand(built["parts"], tp_gun)
	shot_audio = AudioStreamPlayer3D.new()
	shot_audio.stream = Weapon.make_shot_stream(wid)
	shot_audio.unit_size = 8.0
	shot_audio.max_distance = 60.0
	add_child(shot_audio)
	_ability_init()
	last_pos = global_position

func _physics_process(dt: float) -> void:
	_anim_t += dt
	_hit_t += dt
	_spawn_t += dt
	_ability_update(dt)
	if dead:
		velocity.x = move_toward(velocity.x, 0.0, 20.0 * dt)
		velocity.z = move_toward(velocity.z, 0.0, 20.0 * dt)
		velocity.y -= ArenaConfig.GRAVITY * dt
		move_and_slide()
		_animate(dt)
		_death_t += dt
		return
	_think(dt)
	_steer(dt)
	velocity.y -= ArenaConfig.GRAVITY * dt
	move_and_slide()
	_combat(dt)
	_animate(dt)
	# stuck detection -> jump / repick
	if Vector2(velocity.x, velocity.z).length() > 1.0 and global_position.distance_to(last_pos) < 0.05 * dt * 60.0 * 0.2:
		stuck_t += dt
	else:
		stuck_t = 0.0
	last_pos = last_pos.lerp(global_position, 0.1)
	if stuck_t > 0.7:
		stuck_t = 0.0
		if is_on_floor():
			velocity.y = ArenaConfig.JUMP_VELOCITY * 0.9
		_pick_wander()

func _visible_enemies() -> Array:
	if query_enemies.is_valid():
		return query_enemies.call(self)
	return []

func _think(dt: float) -> void:
	strafe_t -= dt
	if strafe_t <= 0.0:
		strafe_t = randf_range(0.8, 1.8)
		strafe_dir = -strafe_dir if randf() < 0.7 else (1.0 if randf() < 0.5 else -1.0)
	# validate enemy
	if enemy != null and (not is_instance_valid(enemy) or bool(enemy.get("dead"))):
		enemy = null
	if enemy == null or randf() < dt * 0.5:
		var cands: Array = _visible_enemies()
		enemy = cands[0] if not cands.is_empty() else null
	var hp_frac: float = health.hp / health.max_hp
	if hp_frac < 0.3 and enemy != null:
		state = B.RETREAT
		var away: Vector3 = (global_position - enemy.global_position).normalized()
		move_target = global_position + away * 14.0 + Vector3(0, 0, 0)
		has_move = true
		return
	if weapon.reloading:
		state = B.RELOAD
		if enemy != null and _has_los(enemy):
			_move_to_cover()
		return
	if weapon.mag <= 0:
		weapon.start_reload()
		state = B.RELOAD
		return
	if enemy == null:
		if state != B.PATROL or not has_move or global_position.distance_to(move_target) < 2.0:
			wander_t -= dt
			if wander_t <= 0.0:
				wander_t = randf_range(2.0, 5.0)
				_pick_wander()
				state = B.PATROL
		return
	var dist := global_position.distance_to(enemy.global_position)
	var rng: float = float(weapon.data["range"])
	if dist > rng * 0.9:
		state = B.CHASE
		move_target = enemy.global_position
		has_move = true
	elif dist < 6.0 and _has_los(enemy):
		# too close: strafe orbit instead of backing into walls
		state = B.ATTACK
		var side := (global_transform.basis.x * strafe_dir).normalized()
		move_target = global_position + side * 5.0
		has_move = true
	else:
		if state != B.ATTACK and state != B.AIM:
			state = B.AIM
			# fair reaction window: 0.5s (low skill) .. 0.3s (high skill)
			react_t = lerpf(0.5, 0.3, skill)
		if state == B.AIM:
			react_t -= dt
			has_move = false
			if react_t <= 0.0:
				state = B.ATTACK
				burst_left = int(lerpf(5.0, 9.0, skill))
				burst_pause = 0.0
		elif state == B.ATTACK:
			# mid-range strafe to avoid being a turret
			var side2 := (global_transform.basis.x * strafe_dir).normalized()
			move_target = global_position + side2 * 4.0
			has_move = true

func _move_to_cover() -> void:
	state = B.TAKE_COVER
	var best := Vector3.ZERO
	var best_d := 1e9
	for c in cover_points:
		var cp: Vector3 = c
		var d := global_position.distance_to(cp)
		if d < best_d:
			best_d = d
			best = cp
	if best_d < 1e8:
		move_target = best
		has_move = true

func _pick_wander() -> void:
	# bias toward midfield so teams actually meet: anchor halfway home→center
	var anchor: Vector3 = home_pos.lerp(Vector3.ZERO, 0.45)
	var a := randf() * TAU
	var r := randf_range(6.0, 22.0)
	move_target = anchor + Vector3(cos(a) * r, 0, sin(a) * r)
	move_target.y = 0.5
	has_move = true

func _steer(dt: float) -> void:
	var face: Vector3 = -global_transform.basis.z
	if enemy != null and (state == B.AIM or state == B.ATTACK or state == B.CHASE):
		var to_e: Vector3 = enemy.global_position - global_position
		to_e.y = 0.0
		if to_e.length() > 0.05:
			face = to_e.normalized()
	elif has_move:
		var to_m: Vector3 = move_target - global_position
		to_m.y = 0.0
		if to_m.length() > 0.6:
			face = to_m.normalized()
	if face.length() > 0.01:
		var target_yaw := atan2(-face.x, -face.z)
		_yaw = lerp_angle(_yaw, target_yaw, minf(1.0, 8.0 * dt))
		rotation.y = _yaw
	var speed := 0.0
	if has_move and state != B.AIM:
		var d := Vector3(move_target.x - global_position.x, 0, move_target.z - global_position.z).length()
		if d > 1.2:
			speed = (4.0 if enemy != null else 3.0) * speed_mod
	# obstacle feeler: turn if wall ahead
	if speed > 0.1 and _blocked_ahead():
		_yaw += 1.2 * dt * 4.0
		rotation.y = _yaw
		if randf() < 0.02 and is_on_floor():
			velocity.y = ArenaConfig.JUMP_VELOCITY * 0.8
	# collision avoidance
	var push := _collision_avoidance()
	if push.length() > 0.01:
		_yaw = atan2(-push.x, -push.z)
		rotation.y = _yaw
	var wish := -global_transform.basis.z * speed
	velocity.x = move_toward(velocity.x, wish.x, ArenaConfig.ACCEL_GROUND * dt)
	velocity.z = move_toward(velocity.z, wish.z, ArenaConfig.ACCEL_GROUND * dt)
	if enemy != null:
		var dy: float = (enemy.global_position.y + 1.3) - (global_position.y + 1.4)
		_aim_pitch = clamp(-dy * 0.15, -0.6, 0.6)

func _blocked_ahead() -> bool:
	var space := get_world_3d().direct_space_state
	var from := global_position + Vector3(0, 0.9, 0)
	var to := from + (-global_transform.basis.z) * 2.2
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = ArenaConfig.mask_world()
	q.exclude = [get_rid()]
	return not space.intersect_ray(q).is_empty()

func _has_los(who: Node3D) -> bool:
	var space := get_world_3d().direct_space_state
	var from := global_position + Vector3(0, 1.5, 0)
	var to: Vector3 = (who as Node3D).global_position + Vector3(0, 1.2, 0)
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = ArenaConfig.mask_world()
	q.exclude = [get_rid()]
	return space.intersect_ray(q).is_empty()

func _combat(dt: float) -> void:
	weapon.trigger_held = false
	weapon.tick(dt)
	if weapon.reloading and weapon.reload_progress() < 0.0:
		pass
	if state == B.ATTACK and enemy != null and is_instance_valid(enemy) and not bool(enemy.get("dead")):
		if not _has_los(enemy):
			state = B.CHASE
			move_target = enemy.global_position
			has_move = true
			return
		if burst_pause > 0.0:
			burst_pause -= dt
			return
		if burst_left <= 0:
			burst_left = int(lerpf(5.0, 9.0, skill))
			burst_pause = randf_range(0.2, 0.5) * (1.2 - skill * 0.5)
			if randf() < 0.3:
				weapon.start_reload()
			return
		# fire one shot attempt this frame; Weapon handles rate via cooldown
		var before := weapon.mag
		weapon.trigger_held = true
		var space := get_world_3d().direct_space_state
		var from: Vector3 = global_position + Vector3(0, 1.5, 0)
		var aim: Vector3 = (enemy.global_position + Vector3(0, 1.1, 0) - from).normalized()
		# skill-based aim error (less while standing still)
		var err := lerpf(0.05, 0.015, skill)
		aim = (aim + Vector3(randf_range(-err, err), randf_range(-err, err), randf_range(-err, err))).normalized()
		var kick: float = weapon.try_fire(space, from, aim, player_id, damage_fn,
			func(a: Vector3, b: Vector3) -> void: FX.tracer(fx_parent, _tp_muzzle_pos(), b))
		if kick > 0.0 or weapon.mag != before:
			if weapon.mag != before:
				burst_left -= 1
				FX.muzzle(tp_gun)
				FX.shell(fx_parent, _tp_muzzle_pos(), global_transform.basis.x)
			shot_audio.pitch_scale = randf_range(0.94, 1.06)
			shot_audio.play()
	elif state == B.AIM:
		weapon.trigger_held = false

func _tp_muzzle_pos() -> Vector3:
	if tp_gun:
		var mz: Node3D = tp_gun.get_node_or_null("Muzzle") as Node3D
		if mz:
			return mz.global_position
	return global_position + Vector3(0, 1.4, 0) + (-global_transform.basis.z)

func _animate(dt: float) -> void:
	if body_parts.is_empty():
		return
	var hspeed := Vector2(velocity.x, velocity.z).length()
	AnimController.pose(body_parts, body_visual, dt, {
		"time": _anim_t, "speed": hspeed, "airborne": not is_on_floor(),
		"vy": velocity.y, "sprinting": hspeed > 4.6, "crouch": false, "prone": false,
		"firing": weapon.trigger_held, "reload_t": weapon.reload_progress(),
		"hit_t": _hit_t, "dead": dead, "death_t": _death_t,
		"aim_pitch": _aim_pitch, "spawn_t": _spawn_t,
	})

# ---- shared combat interface ----
func apply_hit(dmg: float, from_id: int, headshot: bool, _pos: Vector3, _n: Vector3) -> void:
	if dead:
		return
	_hit_t = 0.0
	health.take_damage(dmg, from_id, headshot)
	# snap attention to attacker
	if enemy == null and from_id != player_id:
		pass # GameRoot retargets via perception next think

func _on_died(killer_id: int) -> void:
	dead = true
	_death_t = 0.0
	state = B.DEAD
	weapon.trigger_held = false
	died.emit(player_id, killer_id)

func respawn_at(pos: Vector3, yaw_in: float) -> void:
	position = pos
	_yaw = yaw_in
	rotation.y = yaw_in
	velocity = Vector3.ZERO
	dead = false
	_spawn_t = 0.0
	_hit_t = 99.0
	_death_t = 0.0
	enemy = null
	state = B.PATROL
	_pick_wander()
	health.reset_full()
	_was_cloaked = false
	Abilities.set_cloak_visible(body_visual, true)
	weapon.mag = int(weapon.data["mag"])
	weapon.reserve = Weapon.max_reserve_for(str(weapon.data["key"]))
	weapon.reloading = false
	weapon.cooldown = 0.0

func snapshot() -> Dictionary:
	return {
		"player_id": player_id, "team_id": team_id, "avatar_id": avatar_id,
		"name": display_name, "cloaked": is_cloaked(),
		"position": position, "rotation": Vector2(_yaw, _aim_pitch),
		"velocity": velocity, "health": health.hp if health else 0.0,
		"animation_state": AnimController.anim_state_for(
			Vector2(velocity.x, velocity.z).length(), not is_on_floor(), velocity.y,
			false, false, false),
		"weapon_id": weapon.weapon_id() if weapon else 0,
		"mag": weapon.mag if weapon else 0,
		"reserve": weapon.reserve if weapon else 0,
		"shooting": weapon.trigger_held if weapon else false,
		"reloading": weapon.reloading if weapon else false,
		"timestamp": Time.get_ticks_msec() / 1000.0,
	}

func _ability_init() -> void:
	var preset: Dictionary = AvatarDB.get_preset(avatar_id)
	speed_mod = float(preset.get("speed_mod", 1.0))
	health_mod = float(preset.get("health_mod", 1.0))
	ability_state = Abilities.make_state()
	if health:
		health.max_hp = ArenaConfig.MAX_HP * health_mod
		health.hp = health.max_hp

func is_cloaked() -> bool:
	return str(AvatarDB.get_preset(avatar_id).get("ability", "")) == "cloak" and bool(ability_state.get("active", false))

func pickup_ammo(weapon_key: String, amount: int) -> void:
	if weapon == null:
		return
	if str(weapon.data["key"]) != weapon_key:
		return
	var max_reserve := Weapon.max_reserve_for(weapon_key)
	var add := mini(amount, max_reserve - weapon.reserve)
	if add > 0:
		weapon.reserve += add

func _ability_update(dt: float) -> void:
	Abilities.tick_cooldown(ability_state, dt)
	var preset: Dictionary = AvatarDB.get_preset(avatar_id)
	var ability: String = str(preset.get("ability", ""))
	_ability_timer += dt
	# Bots use abilities opportunistically
	if _ability_timer > 1.0:
		_ability_timer = 0.0
		if Abilities.ready(ability_state) and not dead:
			var should_use := false
			match ability:
				"dash":
					should_use = not is_on_floor() and enemy != null
				"overshield":
					should_use = health.hp / health.max_hp < 0.6
				"regen_field":
					should_use = health.hp / health.max_hp < 0.5
				"cloak":
					should_use = enemy != null and global_position.distance_to(enemy.global_position) < 15.0
			if should_use:
				match ability:
					"dash":
						Abilities.scout_dash(ability_state, self)
					"overshield":
						Abilities.trooper_shield(ability_state, self, health)
					"regen_field":
						Abilities.medic_field(ability_state, self)
					"cloak":
						Abilities.ghost_cloak(ability_state, self)
						Abilities.set_cloak_visible(body_visual, false)
						_was_cloaked = true
	# shield expiry restores max HP
	if ability == "overshield" and _was_shielded() and not bool(ability_state.get("active", false)):
		Abilities.trooper_shield_end(ability_state, self, health)
	# cloak expiry restores visibility
	if ability == "cloak":
		var now_cloaked := bool(ability_state.get("active", false))
		if _was_cloaked and not now_cloaked:
			Abilities.set_cloak_visible(body_visual, true)
		_was_cloaked = now_cloaked
	# medic beacon heals nearby allies
	if ability == "regen_field" and bool(ability_state.get("active", false)):
		var my_pos := global_position
		for c in combatants:
			if is_instance_valid(c) and int(c.get("team_id")) == team_id and not bool(c.get("dead")):
				if (c as Node3D).global_position.distance_to(my_pos) < 4.0:
					(c as Node).apply_hit(-15.0 * dt, -1, false, (c as Node3D).global_position, Vector3.UP)

func _was_shielded() -> bool:
	return health != null and health.max_hp > ArenaConfig.MAX_HP * health_mod + 1.0

func _collision_avoidance() -> Vector3:
	var push := Vector3.ZERO
	for c in combatants:
		if c == self or not is_instance_valid(c) or bool(c.get("dead")):
			continue
		var other: Node3D = c as Node3D
		var diff := global_position - other.global_position
		diff.y = 0.0
		var dist := diff.length()
		if dist < 1.0 and dist > 0.01:
			push += diff.normalized() * (1.0 - dist) * 2.0
	return push.limit_length(3.0)
