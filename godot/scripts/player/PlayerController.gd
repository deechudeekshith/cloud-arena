class_name PlayerController
extends CharacterBody3D

## Human FPS controller with a real tactical stance state machine:
## STANDING / RUNNING / SPRINTING / CROUCHING / PRONE / CRAWLING /
## JUMPING / FALLING. Stance changes collision shape, camera height,
## speed, and animation. Sprint is a ~1s burst (SHIFT+W) with cooldown.
## Clearance is checked before standing up (fences/tunnels work).
##
## Combat interface (shared with bots): apply_hit(), snapshot().

signal health_changed(hp: float, max_hp: float)
signal ammo_changed(mag: int, reserve: int)
signal weapon_changed(idx: int)
signal died(player_id: int, killer_id: int)
signal fired

const MS := ArenaConfig.MoveState

var player_id := 0
var team_id := 0
var avatar_id := 0
var display_name := "Player"
var is_human := true

# avatar modifiers (declared vars — never set()/get() magic)
var speed_mod := 1.0
var health_mod := 1.0

var look_sens := ArenaConfig.MOUSE_SENS_DEFAULT
var invert_y := false
# ADS (aim-down-sights): 0 = hip, 1 = fully aimed. Zooms FOV, tightens
# sensitivity + spread. Driven by the "aim" action (RMB on PC, ADS button).
var aim_factor := 0.0
# ADS latch (scope toggle): with ads_toggle on, one press of the aim action
# keeps the view scoped until the next press; with it off, aim is held.
var ads_toggle := true
var _aim_latched := false
# Aim assist: ease the view toward an enemy already near the crosshair while
# scoped or firing. Off = pure manual aim. Never moves on its own otherwise.
var auto_aim := true
var yaw := 0.0
var pitch := 0.0
var recoil_pitch := 0.0
var dead := false

# stance state
var stance: int = MS.STANDING
var want_crouch := false
var want_prone := false
var sprint_t := 0.0   # burst time left
var sprint_cd := 0.0  # cooldown left

var health: Health
var weapon: Weapon
var weapon_ids := [0, 1, 2]
var weapon_slot := 0
var skin_id := 0

# abilities
var ability_state := {}
var get_combatants: Callable
var _ability_queued := false
var _was_cloaked := false

var head: Node3D
var camera: Camera3D
var body_col: CollisionShape3D
var body_cap: CapsuleShape3D
var viewmodel_root: Node3D
var viewmodel: Node3D
var tp_gun: Node3D # third-person gun mounted in the right hand
var _equip_anim := 0.0 # weapon raise dip on switch
var _fire_kick := 0.0 # viewmodel kickback on fire
var body_visual: Node3D
var body_parts := {}

var damage_fn: Callable
var fx_parent: Node3D
var shot_sound: AudioStreamPlayer
var click_player: AudioStreamPlayer # empty-click + reload-clack voice
var click_stream: AudioStreamWAV
var clack_stream: AudioStreamWAV
var base_fov := 75.0

# Unified input source (PC keyboard/mouse or mobile touch). The controller
# only speaks logical actions; it never touches Input or touch APIs.
var input_provider: GameInput = GameInput.PC.new()
# Server-side body for a remote human: simulated from network input.
var net_controlled := false

var _bob_t := 0.0
var _sway := Vector2.ZERO
var _anim_t := 0.0
var _hit_t := 99.0
var _spawn_t := 99.0
var _land_dip := 0.0
var _was_airborne := false
var _prone_blend := 0.0
var _death_t := 0.0
var _trauma := 0.0 # damage shake: 0 calm .. 1 heavy, decays in _camera_fx

func setup(p_id: int, p_team: int, p_avatar: int, p_name: String, dmg: Callable, fx: Node3D) -> void:
	player_id = p_id
	team_id = p_team
	avatar_id = p_avatar
	display_name = p_name
	damage_fn = dmg
	fx_parent = fx

func _ready() -> void:
	add_to_group("combatant")
	add_to_group("team_%d" % team_id)
	collision_layer = ArenaConfig.mask_body()
	collision_mask = ArenaConfig.mask_world() | ArenaConfig.mask_body()
	floor_snap_length = 0.45
	floor_max_angle = deg_to_rad(50.0)
	floor_block_on_wall = true
	body_col = CollisionShape3D.new()
	body_col.name = "Body"
	body_cap = CapsuleShape3D.new()
	body_col.shape = body_cap
	add_child(body_col)
	_apply_stance_shape()
	# health
	health = Health.new()
	health.max_hp = ArenaConfig.MAX_HP
	health.regen_rate = 10.0 # player auto-regen: 10 HP/s after 5s calm
	health.regen_delay = 5.0
	add_child(health)
	health.damaged.connect(_on_damaged)
	health.died.connect(_on_died)
	# head + camera
	head = Node3D.new()
	head.name = "Head"
	head.position = Vector3(0, ArenaConfig.CAM_STAND_H, 0)
	add_child(head)
	camera = Camera3D.new()
	camera.name = "Camera3D"
	camera.fov = base_fov
	camera.near = 0.05
	camera.far = 400.0
	camera.current = is_human
	head.add_child(camera)
	# third-person humanoid (hidden for local FPS view, hitbox stays live)
	var built: Dictionary = HumanoidBuilder.build(AvatarDB.get_preset(avatar_id), team_id)
	body_visual = built["root"]
	body_parts = built["parts"]
	add_child(body_visual)
	if is_human:
		body_visual.visible = false
	_ability_init()
	# first-person viewmodel
	viewmodel_root = Node3D.new()
	viewmodel_root.name = "Viewmodel"
	camera.add_child(viewmodel_root)
	viewmodel_root.position = Vector3(0.24, -0.22, -0.3)
	viewmodel_root.scale = Vector3.ONE * 0.6
	shot_sound = AudioStreamPlayer.new()
	shot_sound.bus = "Master"
	add_child(shot_sound)
	click_player = AudioStreamPlayer.new()
	click_player.bus = "Master"
	add_child(click_player)
	click_stream = Weapon.make_click_stream(2400.0, 0.05) # empty trigger
	clack_stream = Weapon.make_click_stream(850.0, 0.09) # reload start
	_equip_slot(weapon_slot, true)
	if weapon:
		weapon.set_self_exceptions(_self_rids())

# ---------------- stance ----------------
func is_prone() -> bool:
	return stance == MS.PRONE or stance == MS.CRAWLING

func is_crouched() -> bool:
	return stance == MS.CROUCHING

func is_sprinting() -> bool:
	return stance == MS.SPRINTING

func _apply_stance_shape() -> void:
	if stance == MS.PRONE or stance == MS.CRAWLING:
		body_cap.radius = ArenaConfig.CAPSULE_PRONE_R
		body_cap.height = ArenaConfig.CAPSULE_PRONE_H
		body_col.position = Vector3(0, ArenaConfig.CAPSULE_PRONE_H * 0.5, 0)
	elif stance == MS.CROUCHING:
		body_cap.radius = ArenaConfig.CAPSULE_CROUCH_R
		body_cap.height = ArenaConfig.CAPSULE_CROUCH_H
		body_col.position = Vector3(0, ArenaConfig.CAPSULE_CROUCH_H * 0.5, 0)
	else:
		body_cap.radius = ArenaConfig.CAPSULE_STAND_R
		body_cap.height = ArenaConfig.CAPSULE_STAND_H
		body_col.position = Vector3(0, ArenaConfig.CAPSULE_STAND_H * 0.5, 0)

## Real clearance check: would a capsule of `height`/`radius` at our feet fit?
func _clearance_ok(height: float, radius: float) -> bool:
	var space := get_world_3d().direct_space_state
	var shape := CapsuleShape3D.new()
	shape.height = height
	shape.radius = radius
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = shape
	q.transform = Transform3D(Basis(), global_position + Vector3(0, height * 0.5, 0))
	q.collision_mask = ArenaConfig.mask_world()
	q.collide_with_bodies = true
	q.collide_with_areas = false
	q.exclude = [get_rid()]
	return space.intersect_shape(q, 4).is_empty()

func can_stand() -> bool:
	return _clearance_ok(ArenaConfig.CAPSULE_STAND_H, ArenaConfig.CAPSULE_STAND_R)

func can_crouch() -> bool:
	return _clearance_ok(ArenaConfig.CAPSULE_CROUCH_H, ArenaConfig.CAPSULE_CROUCH_R)

func request_crouch_toggle() -> void:
	if dead:
		return
	if is_prone():
		if can_crouch():
			want_prone = false
			want_crouch = true
	elif is_crouched():
		if can_stand():
			want_crouch = false
	else:
		want_crouch = true
		want_prone = false

func request_prone_toggle() -> void:
	if dead:
		return
	if is_prone():
		if can_crouch():
			want_prone = false
			want_crouch = true
	else:
		want_prone = true
		want_crouch = false

func _resolve_stance(fwd: float, hspeed: float, airborne: bool) -> void:
	if dead:
		return
	if airborne:
		stance = MS.FALLING if velocity.y < 0.5 else MS.JUMPING
		return
	if want_prone:
		stance = MS.CRAWLING if hspeed > 0.25 else MS.PRONE
	elif want_crouch:
		stance = MS.CROUCHING
	elif sprint_t > 0.0 and fwd > 0.1:
		stance = MS.SPRINTING
	elif hspeed > 0.5:
		stance = MS.RUNNING
	else:
		stance = MS.STANDING

func stance_speed(fwd: float, strafe: float) -> float:
	var s := ArenaConfig.NORMAL_SPEED
	match stance:
		MS.SPRINTING:
			s = ArenaConfig.SPRINT_SPEED
		MS.CROUCHING:
			s = ArenaConfig.CROUCH_SPEED
		MS.PRONE, MS.CRAWLING:
			if fwd > 0.1:
				s = ArenaConfig.FORWARD_CRAWL_SPEED
			elif fwd < -0.1:
				s = ArenaConfig.BACKWARD_CRAWL_SPEED
			else:
				s = ArenaConfig.SIDE_CRAWL_SPEED
	return s * speed_mod

func cam_height() -> float:
	if is_prone():
		return ArenaConfig.CAM_PRONE_H
	if is_crouched():
		return ArenaConfig.CAM_CROUCH_H
	return ArenaConfig.CAM_STAND_H

# ---------------- input ----------------
func _unhandled_input(event: InputEvent) -> void:
	if not is_human or dead:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var mm := event as InputEventMouseMotion
		# mouse right -> yaw right; mouse up (relative.y<0) -> pitch up
		_apply_look(Vector2(-mm.relative.x, -mm.relative.y))

## Shared look path for mouse motion and touch drags.
## d.x = yaw right+, d.y = pitch up+ (already sensitivity-scaled).
func _apply_look(d: Vector2) -> void:
	var dy := -d.y if invert_y else d.y
	# ADS steadies the view (up to 45% slower at full aim)
	var s := look_sens * (1.0 - 0.45 * aim_factor)
	yaw += d.x * s
	pitch = clamp(pitch + dy * s, -1.53, 1.53)
	rotation.y = yaw
	head.rotation.x = pitch + recoil_pitch
	_sway = _sway.lerp(Vector2(d.x, dy) * 0.0016, 0.5)

# ---------------- per-frame ----------------
func _physics_process(dt: float) -> void:
	_anim_t += dt
	_hit_t += dt
	_spawn_t += dt
	sprint_cd = maxf(0.0, sprint_cd - dt)
	_ability_update(dt)
	if dead:
		velocity.x = move_toward(velocity.x, 0.0, 20.0 * dt)
		velocity.z = move_toward(velocity.z, 0.0, 20.0 * dt)
		velocity.y -= ArenaConfig.GRAVITY * dt
		move_and_slide()
		_animate(dt)
		return
	# touch look drags (PC mouse look arrives via _unhandled_input events)
	var ld := input_provider.consume_look()
	if ld.length_squared() > 0.0:
		_apply_look(ld)
	if is_human or net_controlled:
		if net_controlled and input_provider is GameInput.Net:
			var np: Vector2 = (input_provider as GameInput.Net).consume_pose()
			if absf(np.x) < 100.0 and absf(np.y) < 100.0:
				yaw = np.x
				pitch = clamp(np.y, -1.53, 1.53)
				rotation.y = yaw
		_human_move(dt)
	velocity.y -= ArenaConfig.GRAVITY * dt
	move_and_slide()
	if net_controlled:
		_net_weapon_tick(dt)
	else:
		_human_weapons(dt)
	_camera_fx(dt)
	_animate(dt)

## Server-side remote body: cooldown/reload only. Shots arrive as
## validated fire events (see GameRoot), never from held state.
func _net_weapon_tick(dt: float) -> void:
	if weapon == null:
		return
	weapon.trigger_held = false
	if input_provider.just_pressed("reload"):
		weapon.start_reload()
	weapon.tick(dt)

func _human_move(dt: float) -> void:
	var mv := input_provider.get_move()
	var fwd := mv.y
	var strafe := mv.x
	var airborne := not is_on_floor()
	# stance toggle keys
	if input_provider.just_pressed("crouch"):
		request_crouch_toggle()
	if input_provider.just_pressed("prone"):
		request_prone_toggle()
	# sprint burst: SHIFT+W, standing only, then cooldown
	if input_provider.just_pressed("sprint"):
		var preset: Dictionary = AvatarDB.get_preset(avatar_id)
		if str(preset.get("ability", "")) == "dash" and airborne:
			_ability_queued = true
		elif (not airborne and not want_crouch and not want_prone
				and fwd > 0.1 and sprint_cd <= 0.0 and sprint_t <= 0.0):
			sprint_t = ArenaConfig.SPRINT_BURST_DURATION
			sprint_cd = ArenaConfig.SPRINT_BURST_DURATION + ArenaConfig.SPRINT_COOLDOWN
	if input_provider.just_pressed("ability"):
		_ability_queued = true
	# sprint cancels when it should be impossible
	if airborne or want_crouch or want_prone or fwd < 0.1:
		sprint_t = 0.0
	else:
		sprint_t = maxf(0.0, sprint_t - dt)
	var hspeed_pre := Vector2(velocity.x, velocity.z).length()
	_resolve_stance(fwd, hspeed_pre, airborne)
	_apply_stance_shape()
	var speed := stance_speed(fwd, strafe)
	var wish := transform.basis * Vector3(strafe, 0, -fwd)
	wish.y = 0.0
	wish = wish.normalized() if wish.length() > 0.01 else Vector3.ZERO
	wish += _collision_avoidance()
	if is_on_floor():
		if wish != Vector3.ZERO:
			velocity.x = move_toward(velocity.x, wish.x * speed, ArenaConfig.ACCEL_GROUND * dt)
			velocity.z = move_toward(velocity.z, wish.z * speed, ArenaConfig.ACCEL_GROUND * dt)
		else:
			velocity.x = move_toward(velocity.x, 0.0, ArenaConfig.FRICTION_GROUND * dt)
			velocity.z = move_toward(velocity.z, 0.0, ArenaConfig.FRICTION_GROUND * dt)
		if input_provider.just_pressed("jump") and not is_prone():
			if is_crouched() and not can_stand():
				pass # blocked: stay crouched
			else:
				want_crouch = false
				velocity.y = ArenaConfig.JUMP_VELOCITY
	else:
		velocity.x = lerpf(velocity.x, wish.x * speed, ArenaConfig.AIR_CONTROL * dt * 4.0)
		velocity.z = lerpf(velocity.z, wish.z * speed, ArenaConfig.AIR_CONTROL * dt * 4.0)
	if input_provider.just_pressed("weapon_1"):
		_equip_slot(0)
	elif input_provider.just_pressed("weapon_2"):
		_equip_slot(1)
	elif input_provider.just_pressed("weapon_3"):
		_equip_slot(2)
	elif input_provider.just_pressed("weapon_cycle"):
		_equip_slot(weapon_slot + 1)
	if _was_airborne and is_on_floor():
		_land_dip = minf(0.18, absf(velocity.y) * 0.008 + 0.06)
	_was_airborne = not is_on_floor()

func _human_weapons(dt: float) -> void:
	if weapon == null:
		return
	# ADS blend: smooth zoom in/out toward the aim state.
	# ads_toggle = true  -> one press latches the scope (tap to enter, tap
	#                       again to leave; the mobile default).
	# ads_toggle = false -> classic hold-to-scope (PC RMB feel).
	var want_aim: bool
	if ads_toggle:
		if input_provider.just_pressed("aim") and not dead:
			_aim_latched = not _aim_latched
		want_aim = _aim_latched and not dead
	else:
		want_aim = input_provider.pressed("aim") and not dead
	aim_factor = move_toward(aim_factor, 1.0 if want_aim else 0.0, dt * 8.0)
	if auto_aim:
		_auto_aim(dt)
	var was_rel := weapon.reloading
	weapon.trigger_held = input_provider.pressed("fire")
	if input_provider.just_pressed("reload"):
		weapon.start_reload()
	weapon.tick(dt)
	var space := get_world_3d().direct_space_state
	var from: Vector3 = camera.global_position
	var dir: Vector3 = -camera.global_transform.basis.z
	var kick: float = weapon.try_fire(space, from, dir, player_id, damage_fn,
		func(a: Vector3, b: Vector3) -> void: FX.tracer(fx_parent, _muzzle_world(), b),
		lerpf(1.0, 0.55, aim_factor))
	if weapon.reloading and not was_rel:
		_play_clack() # reload started (manual or auto-on-empty)
	if kick > 0.0:
		_apply_recoil(kick)
		_fire_kick = 1.0
		FX.muzzle(viewmodel)
		FX.shell(fx_parent, _muzzle_world(), camera.global_transform.basis.x)
		shot_sound.pitch_scale = randf_range(0.96, 1.05)
		shot_sound.play()
		fired.emit()

## Aim assist: while scoped or firing, ease the view toward the nearest
## enemy already inside a narrow cone in front of the crosshair. Limited to a
## small per-frame step so it corrects aim rather than snapping to targets.
const AUTO_AIM_CONE_DEG := 22.0
const AUTO_AIM_RANGE := 70.0
const AUTO_AIM_RATE := 3.0 # rad/s of steer

func _auto_aim(dt: float) -> void:
	if dead or weapon == null:
		return
	# never drifts on its own: only while aimed in or actively shooting
	if aim_factor < 0.35 and not input_provider.pressed("fire"):
		return
	if not get_combatants.is_valid():
		return
	var eye := camera.global_position
	var fwd := -camera.global_transform.basis.z
	var cone := deg_to_rad(AUTO_AIM_CONE_DEG)
	var best_pt := Vector3.ZERO
	var best_ang := cone
	var found := false
	for c in get_combatants.call():
		if not is_instance_valid(c) or c == self:
			continue
		if not (c is Node3D):
			continue
		if int(c.get("team_id")) == team_id or bool(c.get("dead")):
			continue
		var tgt: Vector3 = (c as Node3D).global_position + Vector3.UP * 1.35
		var to := tgt - eye
		var dist := to.length()
		if dist < 0.6 or dist > AUTO_AIM_RANGE:
			continue
		var ang := fwd.angle_to(to)
		if ang >= best_ang:
			continue
		# line of sight: skip if level geometry sits between us and the target
		var q := PhysicsRayQueryParameters3D.create(eye, tgt,
			ArenaConfig.mask_world(), _self_rids())
		if not get_world_3d().direct_space_state.intersect_ray(q).is_empty():
			continue
		best_ang = ang
		best_pt = tgt
		found = true
	if not found:
		return
	var d := best_pt - eye
	var flat := Vector2(d.x, d.z)
	# forward = (-sin(yaw), 0, -cos(yaw)) => yaw that aims at (dx,dz)
	var want_yaw := atan2(-flat.x, -flat.y)
	var want_pitch := atan2(d.y, flat.length())
	var max_step := AUTO_AIM_RATE * dt
	var dy := wrapf(want_yaw - yaw, -PI, PI)
	var dp := want_pitch - pitch
	yaw += clampf(dy, -max_step, max_step)
	pitch = clampf(pitch + clampf(dp, -max_step, max_step), -1.53, 1.53)
	rotation.y = yaw
	head.rotation.x = pitch + recoil_pitch

func _play_click() -> void:
	if click_player and click_stream:
		click_player.stream = click_stream
		click_player.play()

func _play_clack() -> void:
	if click_player and clack_stream:
		click_player.stream = clack_stream
		click_player.play()

func _muzzle_world() -> Vector3:
	if viewmodel:
		var mz: Node3D = viewmodel.get_node_or_null("Muzzle") as Node3D
		if mz:
			return mz.global_position
	return camera.global_position + (-camera.global_transform.basis.z) * 1.0

func _apply_recoil(kick: float) -> void:
	recoil_pitch = clamp(recoil_pitch + kick, 0.0, 0.2)
	pitch = clamp(pitch + kick * 0.6, -1.53, 1.53)
	head.rotation.x = pitch + recoil_pitch

func _camera_fx(dt: float) -> void:
	recoil_pitch = lerpf(recoil_pitch, 0.0, 10.0 * dt)
	if absf(recoil_pitch) < 0.0005:
		recoil_pitch = 0.0
	head.rotation.x = lerpf(head.rotation.x, pitch + recoil_pitch, 18.0 * dt)
	# smooth stance camera height (never teleport)
	head.position.y = lerpf(head.position.y, cam_height(), minf(1.0, 10.0 * dt))
	var hspeed := Vector2(velocity.x, velocity.z).length()
	_bob_t += dt * (4.0 + hspeed * 1.4)
	var bob_scale := 1.0
	if is_sprinting():
		bob_scale = 1.4
	elif is_crouched():
		bob_scale = 0.6
	elif is_prone():
		bob_scale = 0.25
	var bob_amt: float = clamp(hspeed / ArenaConfig.SPRINT_SPEED, 0.0, 1.0) * bob_scale
	if not is_on_floor():
		bob_amt = 0.0
	_land_dip = lerpf(_land_dip, 0.0, 8.0 * dt)
	var bob_y: float = sin(_bob_t * 2.0) * 0.028 * bob_amt - _land_dip
	var bob_x: float = cos(_bob_t) * 0.02 * bob_amt
	camera.position = Vector3(bob_x, bob_y, 0)
	# damage shake: small random rotational jitter, scaled by trauma^2
	_trauma = maxf(0.0, _trauma - dt * 1.6)
	var sh := _trauma * _trauma
	if sh > 0.0001:
		camera.rotation = Vector3(randf_range(-sh, sh) * 0.035,
			randf_range(-sh, sh) * 0.035, 0.0)
	else:
		camera.rotation = Vector3.ZERO
	var target_fov := base_fov + (6.0 if is_sprinting() else 0.0) - 20.0 * aim_factor
	camera.fov = lerpf(camera.fov, target_fov, 6.0 * dt)
	_sway = _sway.lerp(Vector2.ZERO, 8.0 * dt)
	var kick_z := recoil_pitch * 1.2
	# fire kickback + reload dip + equip raise (all decay smoothly)
	_fire_kick = maxf(0.0, _fire_kick - dt * 9.0)
	_equip_anim = maxf(0.0, _equip_anim - dt * 5.0)
	var rp: float = weapon.reload_progress() if weapon else -1.0
	var dip := 0.0
	var dip_rot := 0.0
	if rp >= 0.0:
		dip = sin(rp * PI) * 0.07
		dip_rot = sin(rp * PI) * 0.45
	viewmodel_root.position = viewmodel_root.position.lerp(
		Vector3(0.24 + _sway.x + bob_x * 0.6, -0.22 + _sway.y + bob_y * 0.6 - dip - _equip_anim * 0.14, -0.3 + kick_z + _fire_kick * 0.05), 14.0 * dt)
	viewmodel_root.rotation = Vector3(_sway.y * 2.0 + recoil_pitch * 2.0 + _fire_kick * 0.09 + dip_rot + _equip_anim * 0.5, _sway.x * 2.0, 0)

func _animate(_dt: float) -> void:
	if body_parts.is_empty():
		return
	_prone_blend = clampf(_prone_blend + _dt * 6.0 * (1.0 if is_prone() else -1.0), 0.0, 1.0)
	if not body_visual.visible:
		return
	var hspeed := Vector2(velocity.x, velocity.z).length()
	AnimController.pose(body_parts, body_visual, _dt, {
		"time": _anim_t, "speed": hspeed, "airborne": not is_on_floor(),
		"vy": velocity.y, "sprinting": is_sprinting(),
		"crouch": is_crouched(), "prone": is_prone(), "prone_blend": _prone_blend,
		"firing": weapon != null and weapon.trigger_held,
		"reload_t": weapon.reload_progress() if weapon else -1.0,
		"hit_t": _hit_t, "dead": dead,
		"death_t": _death_t, "aim_pitch": pitch, "spawn_t": _spawn_t,
	})

func _process(dt: float) -> void:
	if dead:
		_death_t += dt

# ---- combat interface ----
func apply_hit(dmg: float, from_id: int, headshot: bool, _pos: Vector3, _n: Vector3) -> void:
	if dead:
		return
	if dmg < 0.0:
		health.heal(-dmg) # regen beacon path
		return
	_hit_t = 0.0
	health.take_damage(dmg, from_id, headshot)

func is_cloaked() -> bool:
	return str(AvatarDB.get_preset(avatar_id).get("ability", "")) == "cloak" and bool(ability_state.get("active", false))

func _on_damaged(amount: float, _from: int, _hs: bool) -> void:
	_trauma = minf(1.0, _trauma + 0.25 + amount / 200.0)
	health_changed.emit(health.hp, health.max_hp)

func _on_died(killer_id: int) -> void:
	dead = true
	_death_t = 0.0
	sprint_t = 0.0
	aim_factor = 0.0
	_aim_latched = false
	if weapon:
		weapon.trigger_held = false
	died.emit(player_id, killer_id)

func respawn_at(pos: Vector3, yaw_in: float) -> void:
	position = pos
	yaw = yaw_in
	pitch = 0.0
	recoil_pitch = 0.0
	rotation.y = yaw
	head.rotation.x = 0.0
	velocity = Vector3.ZERO
	dead = false
	_spawn_t = 0.0
	_hit_t = 99.0
	_trauma = 0.0
	stance = MS.STANDING
	want_crouch = false
	want_prone = false
	sprint_t = 0.0
	sprint_cd = 0.0
	aim_factor = 0.0
	_aim_latched = false
	_prone_blend = 0.0
	_apply_stance_shape()
	head.position.y = ArenaConfig.CAM_STAND_H
	ability_state = Abilities.make_state()
	_was_cloaked = false
	Abilities.set_cloak_visible(body_visual, true)
	health.max_hp = ArenaConfig.MAX_HP * health_mod
	health.reset_full()
	if weapon:
		weapon.mag = int(weapon.data["mag"])
		weapon.reserve = Weapon.max_reserve_for(str(weapon.data["key"]))
		weapon.reloading = false
		weapon.cooldown = 0.0
		ammo_changed.emit(weapon.mag, weapon.reserve)
	health_changed.emit(health.hp, health.max_hp)

func set_body_visible(v: bool) -> void:
	body_visual.visible = v

func pickup_ammo(weapon_key: String, amount: int) -> void:
	if weapon == null:
		return
	if str(weapon.data["key"]) != weapon_key:
		return
	var max_reserve := Weapon.max_reserve_for(weapon_key)
	var add := mini(amount, max_reserve - weapon.reserve)
	if add > 0:
		weapon.reserve += add
		ammo_changed.emit(weapon.mag, weapon.reserve)
		FX.impact(fx_parent, global_position + Vector3(0, 1.2, 0), Vector3.UP, false)

func get_stance_info() -> Dictionary:
	return {
		"state": ArenaConfig.get_state_name(stance),
		"speed": Vector2(velocity.x, velocity.z).length(),
		"normal": ArenaConfig.NORMAL_SPEED,
		"sprint": "READY" if sprint_cd <= 0.0 else "%0.1fs" % sprint_cd,
	}

## Network-ready snapshot (rendering-independent plain data).
func snapshot() -> Dictionary:
	return {
		"player_id": player_id, "team_id": team_id, "avatar_id": avatar_id,
		"name": display_name, "cloaked": is_cloaked(),
		"position": position, "rotation": Vector2(yaw, pitch),
		"velocity": velocity, "health": health.hp if health else 0.0,
		"animation_state": AnimController.anim_state_for(
			Vector2(velocity.x, velocity.z).length(), not is_on_floor(),
			velocity.y, is_sprinting(), is_crouched(), is_prone()),
		"stance": ArenaConfig.get_state_name(stance),
		"mag": weapon.mag if weapon else 0,
		"reserve": weapon.reserve if weapon else 0,
		"weapon_id": weapon.weapon_id() if weapon else 0,
		"shooting": weapon.trigger_held if weapon else false,
		"reloading": weapon.reloading if weapon else false,
		"timestamp": Time.get_ticks_msec() / 1000.0,
	}

# ---------------- abilities ----------------
func _ability_init() -> void:
	var preset: Dictionary = AvatarDB.get_preset(avatar_id)
	speed_mod = float(preset.get("speed_mod", 1.0))
	health_mod = float(preset.get("health_mod", 1.0))
	ability_state = Abilities.make_state()
	if health:
		health.max_hp = ArenaConfig.MAX_HP * health_mod
		health.hp = health.max_hp

func _ability_update(dt: float) -> void:
	Abilities.tick_cooldown(ability_state, dt)
	var preset: Dictionary = AvatarDB.get_preset(avatar_id)
	var ability: String = str(preset.get("ability", ""))
	if _ability_queued and Abilities.ready(ability_state) and not dead:
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
	_ability_queued = false
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
	if ability == "regen_field" and bool(ability_state.get("active", false)) and get_combatants.is_valid():
		var my_pos := global_position
		for c in get_combatants.call():
			if is_instance_valid(c) and int(c.get("team_id")) == team_id and not bool(c.get("dead")):
				if (c as Node3D).global_position.distance_to(my_pos) < 4.0:
					(c as Node).apply_hit(-15.0 * dt, -1, false, (c as Node3D).global_position, Vector3.UP)

func _was_shielded() -> bool:
	return health != null and health.max_hp > ArenaConfig.MAX_HP * health_mod + 1.0

func _self_rids() -> Array[RID]:
	var out: Array[RID] = [get_rid()]
	var hb: Area3D = _head_area()
	if hb:
		out.append(hb.get_rid())
	return out

func _head_area() -> Area3D:
	if body_parts.is_empty():
		return null
	var h: Node3D = body_parts.get("Head")
	if h == null:
		return null
	return h.get_node_or_null("HeadHitbox") as Area3D

func _collision_avoidance() -> Vector3:
	var push := Vector3.ZERO
	if not get_combatants.is_valid():
		return push
	for c in get_combatants.call():
		if c == self or not is_instance_valid(c) or bool(c.get("dead")):
			continue
		var diff := global_position - (c as Node3D).global_position
		diff.y = 0.0
		var dist := diff.length()
		if dist < 1.0 and dist > 0.01:
			push += diff.normalized() * (1.0 - dist) * 2.0
	return push.limit_length(3.0)

func _equip_slot(slot: int, force := false) -> void:
	if weapon_slot == slot and not force:
		return
	weapon_slot = posmod(slot, weapon_ids.size())
	var wid: int = weapon_ids[weapon_slot]
	if weapon:
		weapon.queue_free()
	weapon = Weapon.create(wid)
	add_child(weapon)
	weapon.auto_reload = true # fire on empty reloads; R reloads manually
	weapon.ammo_changed.connect(func(m: int, r: int) -> void: ammo_changed.emit(m, r))
	weapon.empty_clicked.connect(_play_click)
	weapon.set_self_exceptions(_self_rids())
	shot_sound.stream = Weapon.make_shot_stream(wid)
	if viewmodel:
		viewmodel.queue_free()
	viewmodel = WeaponViewBuilder.build_viewmodel(wid, skin_id)
	viewmodel_root.add_child(viewmodel)
	_equip_anim = 1.0 # raise animation for the new gun
	if tp_gun and is_instance_valid(tp_gun):
		tp_gun.queue_free()
	tp_gun = WeaponViewBuilder.build_worldmodel(wid, skin_id)
	HumanoidBuilder.attach_weapon_to_hand(body_parts, tp_gun)
	weapon_changed.emit(weapon_slot)
	ammo_changed.emit(weapon.mag, weapon.reserve)
