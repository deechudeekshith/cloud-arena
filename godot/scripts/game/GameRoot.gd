extends Node3D
## GameRoot: boot, arena, match flow (MENU→COUNTDOWN→PLAYING→GAMEOVER),
## spawning, scoring, respawns, pause, HUD/menus glue.
## Gameplay works fully offline; networking stays in NetworkState module.

enum Phase { MENU, COUNTDOWN, PLAYING, GAMEOVER }

const BOT_NAMES := ["Vex", "Rook", "Nova", "Juno", "Kilo", "Ash", "Blitz"]

var phase: int = Phase.MENU
var settings: GameSettings
var arena: Node3D
var fighters: Node3D
var fx: Node3D
var hud: HUD
var menus: Menus
var perf: PerfHUD
var touch_ui: TouchUI
var dash: Dashboard
var menu_cam: Camera3D

var combatants: Array = []
var player: PlayerController = null
var covers: Array = []
var spawns := {"blue": [], "red": []}
var stats := {} # id -> {name, team, kills, deaths, score}
var team_scores := [0, 0]
var dead_timers := {} # id -> seconds left
var time_left := ArenaConfig.MATCH_TIME_SEC
var countdown := 0.0
var menu_orbit := 0.0
var paused := false

# rooms (Phase 4: local registry + lobby; net transport lands in Phase 5)
var room_mgr: RoomManager
var discovery: RoomDiscovery
var my_room_code := ""
var my_pid := ""
var am_host := false

func _ready() -> void:
	InputSetup.ensure()
	settings = GameSettings.load()
	settings.apply(get_window())
	# world containers
	arena = Node3D.new()
	arena.name = "Arena"
	add_child(arena)
	var built: Dictionary = ArenaBuilder.build(arena)
	covers = built["covers"]
	spawns["blue"] = built["spawns_blue"]
	spawns["red"] = built["spawns_red"]
	fighters = Node3D.new()
	fighters.name = "Fighters"
	add_child(fighters)
	fx = Node3D.new()
	fx.name = "FX"
	add_child(fx)
	FX.ensure_pools(fx)
	# UI
	hud = HUD.new()
	hud.name = "HUD"
	add_child(hud)
	hud.visible = false
	menus = Menus.new()
	menus.name = "Menus"
	add_child(menus)
	menus.bind_settings(settings)
	menus.play_pressed.connect(start_match)
	menus.rematch_pressed.connect(start_match)
	menus.quit_to_menu.connect(to_menu)
	menus.resume_pressed.connect(toggle_pause.bind(false))
	menus.quit_game.connect(func() -> void: get_tree().quit())
	menus.avatar_preview.connect(func(id: int) -> void:
		settings.avatar_id = id
		settings.save())
	menus.create_room_pressed.connect(_on_create_room)
	menus.join_code_submitted.connect(_on_join_code)
	menus.leave_room_pressed.connect(_on_leave_room)
	menus.ready_toggled.connect(_on_ready_toggled)
	menus.room_start_pressed.connect(_on_room_start)
	menus.copy_code_pressed.connect(_on_copy_code)
	menus.join_manual_pressed.connect(_on_join_manual)
	menus.touch_customize_closed.connect(func() -> void:
		touch_ui.apply_settings_full(settings))
	menus.results_pressed.connect(func() -> void: dash.show_browser())
	menus.details_pressed.connect(func() -> void:
		if last_match_id != "":
			dash.show_match(last_match_id)
		else:
			dash.show_browser())
	menus.join_screen_opened.connect(func() -> void:
		discovery.start_listening()
		menus.refresh_found(discovery.found))
	# server monitor (this PC is the server) + lobby codec readout
	menus.rooms_provider = _server_rooms_snapshot
	menus.netstats_provider = _lobby_netstats
	room_mgr = RoomManager.new()
	room_mgr.name = "RoomManager"
	add_child(room_mgr)
	room_mgr.lobby_changed.connect(_on_lobby_changed)
	discovery = RoomDiscovery.new()
	discovery.name = "Discovery"
	add_child(discovery)
	discovery.found_updated.connect(_on_found_updated)
	perf = PerfHUD.new()
	add_child(perf)
	dash = Dashboard.new()
	dash.name = "Dashboard"
	add_child(dash)
	touch_ui = TouchUI.new()
	touch_ui.name = "TouchUI"
	add_child(touch_ui)
	touch_ui.apply_settings_full(settings)
	touch_ui.set_match_visible(false)
	touch_ui.pause_requested = toggle_pause
	# local research monitor link (additive; game runs fine without service)
	monitor = MonitorLink.new()
	monitor.name = "MonitorLink"
	monitor.game = self
	add_child(monitor)
	# stable per-process device identity (model + a run-scoped suffix)
	device_name = OS.get_name()
	device_platform = OS.get_name()
	device_id = "%s-%d-%d" % [device_name.to_lower().replace(" ", "_"),
		OS.get_process_id(), Time.get_ticks_msec() % 100000]
	monitor.device_id = device_id
	join_alerts = settings.join_alerts
	# default monitor target: loopback / env override. A joining client
	# re-resolves against the host it connects to (see _start_net_join).
	monitor.resolve_base_url()
	# menu orbit camera (arena backdrop behind main menu)
	menu_cam = Camera3D.new()
	menu_cam.name = "MenuCam"
	menu_cam.fov = 60.0
	menu_cam.far = 400.0
	menu_cam.current = true
	add_child(menu_cam)
	_apply_quality()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _apply_quality() -> void:
	var q := settings.quality
	for n in arena.get_children():
		if n is CPUParticles3D and (n as Node).name == "DustMotes":
			(n as CPUParticles3D).amount = 20 if q == 0 else (60 if q == 1 else 120)
	for l in get_tree().get_nodes_in_group("sun"):
		pass
	var sun := arena.get_node_or_null("Sun")
	if sun is DirectionalLight3D:
		(sun as DirectionalLight3D).shadow_enabled = q >= 1

# ---------------- match flow ----------------
func start_match() -> void:
	_teardown_net()
	_clear_fighters()
	var amode := "OFFLINE"
	var acode := ""
	var aseed := 0
	var humans := 1
	var bots := 7
	if not active_experiment.is_empty() and my_room_code != "":
		amode = str(active_experiment.get("mode", "OFFLINE"))
		acode = str(active_experiment.get("room_code", ""))
		aseed = int(active_experiment.get("map_seed", 0))
		var room := room_mgr.get_room(my_room_code)
		if not room.is_empty():
			humans = room_mgr.human_count(room)
			bots = (room["players"] as Array).size() - humans
	begin_metrics(amode, acode, aseed, humans, bots, "offline" if amode == "OFFLINE" else "local-room")
	team_scores = [0, 0]
	stats.clear()
	dead_timers.clear()
	time_left = ArenaConfig.MATCH_TIME_SEC
	# human (team 0)
	player = PlayerController.new()
	player.is_human = true
	player.setup(0, 0, settings.avatar_id, "You",
		Callable(self, "deal_damage"), fx)
	player.get_combatants = func() -> Array: return combatants
	player.skin_id = settings.skin_id
	fighters.add_child(player)
	_register(player)
	# 3 ally bots (team 0), 4 enemy bots (team 1)
	var specs := [
		[1, 0], [2, 0], [3, 0],
		[4, 1], [5, 1], [6, 1], [7, 1],
	]
	for s in specs:
		var bid: int = s[0]
		var bteam: int = s[1]
		var bot := BotController.new()
		bot.setup(bid, bteam, (bid + settings.avatar_id) % AvatarDB.count(),
			BOT_NAMES[(bid - 1) % BOT_NAMES.size()],
			Callable(self, "visible_enemies_for"), Callable(self, "deal_damage"),
			fx, covers, _spawn_pos(bteam, bid), randf_range(0.35, 0.8))
		fighters.add_child(bot)
		_register(bot)
		bot.combatants = combatants
		if bot.weapon:
			bot.weapon.auto_reload = true
	# spawn ammo pickups (clear last match's first)
	get_tree().call_group("pickup", "queue_free")
	PickupItem.spawn_random(arena, 12, covers)
	for c in combatants:
		var t: int = c.team_id
		c.respawn_at(_spawn_pos(t, c.player_id), _spawn_yaw(t))
		c.set_physics_process(false)
	phase = Phase.COUNTDOWN
	countdown = ArenaConfig.COUNTDOWN_SEC
	paused = false
	menus.hide_all()
	hud.visible = true
	hud.bind(player)
	hud.show_respawn(0.0)
	player.camera.current = true
	_assign_player_input()
	if touch_active():
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _register(c: Node) -> void:
	combatants.append(c)
	stats[c.player_id] = {"name": c.display_name, "team": c.team_id,
		"kills": 0, "deaths": 0, "score": 0}
	c.died.connect(_on_died)
	if c is PlayerController and (c as PlayerController).is_human:
		(c as PlayerController).health_changed.connect(func(_h: float, _m: float) -> void: hud.damage_flash())

func _clear_fighters() -> void:
	for c in combatants:
		if is_instance_valid(c):
			c.queue_free()
	combatants.clear()
	player = null

func to_menu() -> void:
	_clear_fighters()
	_teardown_net()
	_leave_room_silent()
	phase = Phase.MENU
	paused = false
	menus.show_screen("MAIN")
	hud.visible = false
	touch_ui.set_match_visible(false)
	menu_cam.current = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().paused = false

## Touch controls are active when forced on, or in auto mode on a
## touchscreen device. Never decided by resolution alone.
func touch_active() -> bool:
	if settings.touch_mode == 1:
		return true
	if settings.touch_mode == 2:
		return false
	return DisplayServer.is_touchscreen_available()

func _assign_player_input() -> void:
	touch_ui.apply_settings_full(settings)
	if touch_active():
		player.input_provider = touch_ui.provider
	else:
		player.input_provider = GameInput.PC.new()
	# look tuning comes from Settings (both PC and touch funnels use it)
	player.look_sens = settings.sens
	player.invert_y = settings.invert_y
	player.ads_toggle = settings.ads_toggle
	player.auto_aim = settings.auto_aim
	touch_ui.set_match_visible(touch_active())

func toggle_pause(force_off := false) -> void:
	if phase != Phase.PLAYING and not paused:
		return
	paused = false if force_off else not paused
	if paused:
		menus.show_screen("PAUSE")
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		touch_ui.set_match_visible(false)
	else:
		menus.hide_all()
		touch_ui.set_match_visible(touch_active())
		if touch_active():
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _physics_process(_dt: float) -> void:
	_pending_tick()
	if paused:
		return
	if net_mode == "host" and (phase == Phase.PLAYING or phase == Phase.COUNTDOWN):
		_host_broadcast(get_physics_process_delta_time())
	elif net_mode == "client" and player and phase == Phase.PLAYING:
		_client_send_input()
	# pending hello goes out once the ENet link is up
	if _pending_hello and net and net.connected and not net.is_host and multiplayer.get_unique_id() > 1:
		_pending_hello = false
		net.send_hello({"proto": 1, "code": pending_code, "name": settings.player_name,
			"device": device_id, "device_name": device_name,
			"platform": device_platform, "avatar": settings.avatar_id})

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause"):
		if phase == Phase.PLAYING:
			toggle_pause()
		elif paused:
			toggle_pause(true)

const GAME_PORT := 7777

# Active room experiment context (mode/seed recorded for metrics, Phase 10).
var active_experiment := {}

# ---------------- server monitor ----------------
## Every room hosted by this PC, with full details + live match stats for
## the active one. Feeds Menus' SERVER ROOMS screen (1 Hz refresh).
func _server_rooms_snapshot() -> Array:
	var out: Array = []
	if room_mgr == null:
		return out
	var phase_names := ["MENU", "COUNTDOWN", "PLAYING", "GAMEOVER"]
	for code in room_mgr.rooms:
		var room: Dictionary = room_mgr.rooms[code]
		var entry := {
			"code": str(code), "state": str(room.get("state", "?")),
			"mode": str(room.get("mode", "?")),
			"map_seed": str(room.get("map_seed", "?")),
			"created_at": str(room.get("created_at", "?")),
			"max_players": int(room.get("max_players", 8)),
			"players": (room.get("players", []) as Array).duplicate(),
			"is_mine": str(code) == my_room_code,
			"live": "",
		}
		if str(code) == my_room_code and my_room_code != "" and phase != Phase.MENU:
			var live := "phase %s  •  BLUE %d — %d RED" % [
				phase_names[clampi(phase, 0, 3)], team_scores[0], team_scores[1]]
			if phase == Phase.PLAYING:
				live += "  •  %d:%02d left" % [int(time_left) / 60, int(time_left) % 60]
			if net != null and net_mode == "host":
				live += "  •  net %d KB ↑ / %d KB ↓" % [
					net.bytes_sent / 1024, net.bytes_received / 1024]
				live += "  •  codec " + _codec_summary()
			elif net_mode == "":
				live += "  •  offline"
			entry["live"] = live
		out.append(entry)
	return out

## One-line codec summary: mode + measured original vs transferred bytes.
func _codec_summary() -> String:
	var m := comm.mode if comm else "?"
	if metric_opt_orig > 0.0:
		var pct := 100.0 * (1.0 - metric_opt_sent / metric_opt_orig)
		var extra := ""
		if comm and comm.opt:
			var st: Dictionary = (comm.opt as OptimizedCodec).stats()
			extra = "  •  Δ%d full%d repeat%d" % [
				int(st.get("deltas", 0)), int(st.get("fulls", 0)),
				int(st.get("repeats", 0))]
		return "%s %.0f→%.0f KB (saved %0.1f%%)%s" % [m,
			metric_opt_orig / 1024.0, metric_opt_sent / 1024.0, pct, extra]
	return "%s (warming up)" % m

## Lobby codec line for the ROOM screen (host view).
func _lobby_netstats() -> String:
	var room := room_mgr.get_room(my_room_code) if room_mgr else {}
	if room.is_empty():
		return ""
	var mode := str(room.get("mode", "?"))
	if net_mode == "host" and phase == Phase.PLAYING:
		return "⚡ %s active  •  %s" % [mode, _codec_summary()]
	if mode == "OPTIMIZED":
		return "⚡ OPTIMIZED: delta + dedup + compressed snapshots when the match starts"
	return "Mode NORMAL: full-state snapshots (no compression)"
func _on_create_room() -> void:
	var room := room_mgr.create_room(settings.player_name, settings.avatar_id)
	if room.is_empty():
		return
	my_room_code = str(room["code"])
	my_pid = str(room["host_pid"])
	am_host = true
	_ensure_net()
	if not net.host(GAME_PORT):
		menus.lobby_message("Could not open port %d (another host running?)" % GAME_PORT)
	discovery.start_hosting(my_room_code, GAME_PORT, settings.player_name,
		1, RoomManager.MAX_PLAYERS)
	menus.show_lobby(room, my_pid, true)
	_monitor_event("ROOM_CREATED", {
		"room_code": my_room_code,
		"room_id": str(room.get("room_id", "")),
		"max_players": int(room.get("max_players", 8)),
		"mode": str(room.get("mode", "NORMAL")),
		"host_device": device_id, "host_name": settings.player_name})

func _on_join_code(code: String) -> void:
	var res := room_mgr.join_room(code, settings.player_name, settings.avatar_id)
	if bool(res.get("ok", false)):
		my_room_code = code
		my_pid = str(res["player"]["pid"])
		am_host = false
		menus.show_lobby(res["room"], my_pid, false)
		return
	var err := str(res.get("error", "Room not found"))
	if err == "Room not found" and discovery.found.has(code):
		# same-process miss but LAN-visible: join over the network
		var info: Dictionary = discovery.found[code]
		_start_net_join(str(info.get("ip", "127.0.0.1")), int(info.get("port", GAME_PORT)), code)
		return
	menus.join_error_message(err)

func _on_leave_room() -> void:
	_leave_room_silent()
	menus.show_screen("MAIN")
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _leave_room_silent() -> void:
	if my_room_code != "":
		room_mgr.remove_player(my_room_code, my_pid)
		my_room_code = ""
		my_pid = ""
		am_host = false
	discovery.stop()
	_teardown_net()

func _on_ready_toggled() -> void:
	if net_mode == "client" and net:
		net.send_ready() # remote guest: host records it
		return
	if my_room_code == "" or am_host:
		return
	var room := room_mgr.get_room(my_room_code)
	if room.is_empty():
		return
	for pl in room["players"]:
		if str(pl["pid"]) == my_pid:
			room_mgr.set_ready(my_room_code, my_pid, not bool(pl["ready"]))

func _on_room_start() -> void:
	if my_room_code == "" or not am_host:
		return
	var room := room_mgr.get_room(my_room_code)
	if room.is_empty():
		return
	room_mgr.set_mode(my_room_code, "OPTIMIZED" if menus.room_mode_opt.selected == 1 else "NORMAL")
	if _net_has_guests():
		start_net_host() # real multiplayer match (locks room, notifies guests)
		return
	var want_bots: int = menus.room_bot_opt.selected
	while (room["players"] as Array).size() < RoomManager.MAX_PLAYERS and want_bots > 0:
		var idx: int = (room["players"] as Array).size() % BOT_NAMES.size()
		if room_mgr.add_bot(room, BOT_NAMES[idx] + " (bot)", (idx + 1) % AvatarDB.count()).is_empty():
			break
		want_bots -= 1
	# auto-fill remaining slots with bots so matches are always full
	while (room["players"] as Array).size() < RoomManager.MAX_PLAYERS:
		var idx2: int = (room["players"] as Array).size() % BOT_NAMES.size()
		if room_mgr.add_bot(room, BOT_NAMES[idx2] + " (bot)", (idx2 + 1) % AvatarDB.count()).is_empty():
			break
	room_mgr.lock_room(my_room_code)
	room_mgr.set_state(my_room_code, "PLAYING")
	discovery.stop()
	active_experiment = {"room_code": my_room_code, "mode": str(room["mode"]),
		"map_seed": int(room["map_seed"])}
	start_match()

func _on_copy_code() -> void:
	if my_room_code != "":
		DisplayServer.clipboard_set(my_room_code)
		menus.lobby_message("Code copied to clipboard")

func _on_lobby_changed(code: String) -> void:
	if code != my_room_code:
		return
	if phase == Phase.MENU:
		var room := room_mgr.get_room(code)
		if room.is_empty():
			menus.show_screen("MAIN")
			my_room_code = ""
		else:
			discovery.update_presence((room["players"] as Array).size())
			menus.show_lobby(room, my_pid, am_host)

func _on_found_updated() -> void:
	menus.refresh_found(discovery.found)

# ---------------- per-frame ----------------
func _process(dt: float) -> void:
	if phase == Phase.MENU:
		menu_orbit += dt * 0.08
		menu_cam.position = Vector3(cos(menu_orbit) * 55.0, 26.0, sin(menu_orbit) * 55.0)
		menu_cam.look_at(Vector3(0, 2, 0))
		return
	if phase == Phase.COUNTDOWN:
		countdown -= dt
		hud.announce("MATCH STARTS IN %d" % int(ceili(countdown)), 0.2)
		if countdown <= 0.0:
			phase = Phase.PLAYING
			for c in combatants:
				if is_instance_valid(c):
					c.set_physics_process(true)
			if player:
				player.set_physics_process(true)
			hud.announce("FIGHT!", 1.2)
			# the real roster is only known now (bots fill at match start):
			# correct the recorded metadata before any sample is stored
			var humans_n := 0
			for c in combatants:
				if c is PlayerController and not bool((c as PlayerController).net_controlled):
					humans_n += 1
			match_meta["player_count"] = combatants.size()
			match_meta["humans"] = humans_n
			match_meta["bots"] = combatants.size() - humans_n
			monitor_events.append({"type": "MATCH_STARTED",
				"t": Time.get_ticks_msec() / 1000.0, "match_id": match_id,
				"meta": match_meta.duplicate()})
		return
	if net_mode == "client":
		if phase == Phase.PLAYING and not paused:
			_live_sync_settings()
			if not metrics_paused:
				metrics.update(dt, _metrics_ctx())
			_client_driver(dt)
		return
	if phase != Phase.PLAYING or paused:
		return
	_live_sync_settings()
	if not metrics_paused:
		metrics.update(dt, _metrics_ctx())
	time_left -= dt
	# respawns
	var done: Array = []
	for id in dead_timers:
		dead_timers[id] -= dt
		if id == 0 and player:
			hud.show_respawn(maxf(0.0, dead_timers[id]))
		if dead_timers[id] <= 0.0:
			done.append(id)
	for id in done:
		dead_timers.erase(id)
		_respawn(id)
		if id == 0:
			hud.show_respawn(0.0)
	# hud
	hud.set_match(time_left, team_scores[0], team_scores[1])
	if time_left <= 0.0:
		end_match()

## Applies look/audio tuning live every frame, so changes made in the
## pause-menu Settings screen take effect immediately mid-match.
func _live_sync_settings() -> void:
	if player:
		player.look_sens = settings.sens
		player.invert_y = settings.invert_y
		player.ads_toggle = settings.ads_toggle
		player.auto_aim = settings.auto_aim
	if touch_ui:
		touch_ui.look_gain = 2.2 * settings.touch_look_sens

func end_match() -> void:
	phase = Phase.GAMEOVER
	for c in combatants:
		if is_instance_valid(c):
			c.set_physics_process(false)
			if c is BotController:
				(c as BotController).weapon.trigger_held = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	touch_ui.set_match_visible(false)
	var winner := 0 if team_scores[0] > team_scores[1] else (1 if team_scores[1] > team_scores[0] else -1)
	var rows: Array = []
	for id in stats:
		var d: Dictionary = stats[id]
		rows.append(d)
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["score"]) > int(b["score"]))
	if net_mode == "host" and net:
		net.send_event({"proto": 1, "kind": "match_over", "winner": winner,
			"s0": team_scores[0], "s1": team_scores[1], "rows": rows})
	_save_match()
	menus.show_results(winner, team_scores[0], team_scores[1], rows)

# ---------------- combat ----------------
func deal_damage(target: Node, dmg: float, shooter_id: int, headshot: bool, pos: Vector3, normal: Vector3, surface := "dust") -> void:
	if phase != Phase.PLAYING:
		return
	if target == null:
		FX.impact(fx, pos, normal, false, surface)
		return
	if not is_instance_valid(target) or bool(target.get("dead")):
		return
	# Friendly fire is OFF (all modes are team-based): a shooter can never
	# damage a teammate, whether human or bot. Blocked before apply_hit so
	# no damage, no hitmarker, no score event is produced.
	if shooter_id >= 0 and stats.has(shooter_id) and target.has_method("apply_hit"):
		var speaking_team: int = int((stats[shooter_id] as Dictionary).get("team", -1))
		if speaking_team >= 0 and int(target.get("team_id")) == speaking_team:
			return
	target.apply_hit(dmg, shooter_id, headshot, pos, normal)
	FX.impact(fx, pos, normal, headshot, "flesh")
	if shooter_id == 0 and player:
		var killed := false
		if is_instance_valid(target) and target.health:
			killed = not (target.health as Health).alive
		hud.hitmarker(headshot, killed)

func _on_died(victim_id: int, killer_id: int) -> void:
	if not stats.has(victim_id):
		return
	stats[victim_id]["deaths"] += 1
	var vteam: int = stats[victim_id]["team"]
	var vname: String = stats[victim_id]["name"]
	var kname := "WORLD"
	var kteam := -1
	if stats.has(killer_id):
		stats[killer_id]["kills"] += 1
		stats[killer_id]["score"] += 1
		kname = stats[killer_id]["name"]
		kteam = stats[killer_id]["team"]
		team_scores[kteam] += 1
		if killer_id == 0 and player:
			hud.announce("☠  ELIMINATED %s" % vname, 1.0)
	hud.killfeed(vname, kname, false, vteam, kteam if kteam >= 0 else vteam)
	var victim := _by_id(victim_id)
	if victim:
		FX.death_poof(fx, victim.global_position,
			ArenaConfig.TEAM_COLORS[vteam % 2])
	dead_timers[victim_id] = ArenaConfig.RESPAWN_SEC
	if victim_id == 0:
		hud.show_respawn(ArenaConfig.RESPAWN_SEC)
	if net_mode == "host" and net:
		net.send_event({"proto": 1, "kind": "died", "victim_id": victim_id,
			"victim": vname, "vteam": vteam, "killer": kname, "kteam": kteam,
			"shooter": killer_id, "killed": true, "headshot": false,
			"pos": (_by_id(victim_id).global_position if _by_id(victim_id) else Vector3.ZERO)})

func _respawn(pid: int) -> void:
	var c := _by_id(pid)
	if c == null:
		return
	c.respawn_at(_spawn_pos(c.team_id, pid), _spawn_yaw(c.team_id))
	if net_mode == "host" and net:
		net.send_event({"proto": 1, "kind": "respawn", "pid": pid,
			"pos": c.global_position, "yaw": _spawn_yaw(c.team_id)})

func _by_id(pid: int) -> Node:
	for c in combatants:
		if is_instance_valid(c) and c.player_id == pid:
			return c
	return null

func visible_enemies_for(bot: BotController) -> Array:
	var out: Array = []
	for c in combatants:
		if c == bot or not is_instance_valid(c) or bool(c.get("dead")):
			continue
		if int(c.team_id) == int(bot.team_id):
			continue
		if c.has_method("is_cloaked") and (c as Node).call("is_cloaked"):
			continue # Ghost cloak hides from bot perception
		var dist: float = (c as Node3D).global_position.distance_to((bot as Node3D).global_position)
		if dist > 48.0:
			continue
		# field of view: frontal 100° (50° each side)
		var to: Vector3 = ((c as Node3D).global_position - (bot as Node3D).global_position).normalized()
		var fwd: Vector3 = -((bot as Node3D).global_transform.basis.z)
		if dist > 12.0 and fwd.dot(to) < 0.64: # cos(50°) ≈ 0.64
			continue
		# line of sight
		var space := bot.get_world_3d().direct_space_state
		var from: Vector3 = (bot as Node3D).global_position + Vector3(0, 1.5, 0)
		var dst: Vector3 = (c as Node3D).global_position + Vector3(0, 1.2, 0)
		var q := PhysicsRayQueryParameters3D.create(from, dst)
		q.collision_mask = ArenaConfig.mask_world()
		q.exclude = [(bot as CollisionObject3D).get_rid()]
		if not space.intersect_ray(q).is_empty():
			continue
		out.append(c)
	out.sort_custom(func(a: Node3D, b: Node3D) -> bool:
		return a.global_position.distance_squared_to(bot.global_position) < b.global_position.distance_squared_to(bot.global_position))
	return out

func _spawn_pos(team: int, pid: int) -> Vector3:
	var arr: Array = spawns["blue"] if team == 0 else spawns["red"]
	return arr[posmod(pid, arr.size())]

func _spawn_yaw(team: int) -> float:
	return -PI * 0.5 if team == 0 else PI * 0.5

## Offline snapshot hook for future experiments / metrics.
func get_match_snapshot() -> Dictionary:
	return NetworkState.snapshot_match(combatants, team_scores, time_left)

# ================================================================
# NET MULTIPLAYER (Phase 5): authoritative host + predicted clients
# Host runs the full sim (server bodies + bots) reusing every offline
# system. Clients predict locally; host snapshots + events rule.
# ================================================================
var net_mode := "" # "", "host", "client"
var net: NetTransport
var comm: CommManager
var peer_pid := {} # enet peer_id -> room pid (String)
var combatant_peer := {} # combatant int id -> peer_id
var last_fire_msec := {} # combatant int id -> msec (server shot validation)
var puppets := {} # combatant int id -> RemotePuppet (client side)
var puppet_wid := {} # combatant int id -> weapon id shown
var my_net_id := -1
var snap_seq := 0
var broadcast_acc := 0.0
var input_acc := 0.0
var input_seq := 0
var client_respawn_left := 0.0
var client_aim_from := Vector3.ZERO
var client_aim_dir := Vector3.FORWARD
var client_wired_weapon: Weapon
var net_boxes: Array = []
var net_room: Dictionary = {} # guest-side lobby copy
var pending_code := ""

var last_snap_time := 180.0
var last_snap_scores := [0, 0]
var clock_offset := 0.0

# metrics + storage (Phase 10-11): every match records locally
var metrics := MetricsCollector.new()
var storage := MatchStorage.LocalProvider.new()
var match_meta := {}
var match_id := ""
var last_match_id := ""
var metric_opt_orig := 0.0
var metric_opt_sent := 0.0
var metric_opt_saved := 0.0
var client_kills := 0
var client_deaths := 0
# research monitor link (additive telemetry + safe commands)
var monitor: MonitorLink
var metrics_paused := false
var experiment_id := ""
var monitor_events: Array = []
var _sent_samples := 0
# device identity for the room/session monitor (stable per process)
var device_id := ""
var device_name := ""
# Host-side "someone is knocking" alert (desktop notification + beep + banner)
var join_alerts := true
var join_banner_text := ""
var join_banner_t := 0.0
var device_platform := ""
# Joins held for host approval (settings.approve_joins). Keyed by ENet peer
# id; the dashboard (or the timeout) decides, then the join completes.
var pending_joins := {}
const PENDING_TIMEOUT := 30.0 # seconds before an untouched request auto-approves

func begin_metrics(mode: String, room_code: String, map_seed: int, humans: int, bots: int, netconf: String) -> void:
	var dt := Time.get_datetime_dict_from_system()
	# process id suffix: headless research runs are launched concurrently by
	# the benchmark/ablation runner, and a second-resolution id would collide
	match_id = "m%04d%02d%02d_%02d%02d%02d_%d" % [dt["year"], dt["month"], dt["day"],
		dt["hour"], dt["minute"], dt["second"], OS.get_process_id()]
	match_meta = {"match_id": match_id, "room_id": room_code, "mode": mode,
		"map": "arena", "map_seed": map_seed, "player_count": humans + bots,
		"humans": humans, "bots": bots, "duration": int(ArenaConfig.MATCH_TIME_SEC),
		"game_version": MetricsCollector.GAME_VERSION, "net": netconf,
		"sampling": 0.5, "timestamp": Time.get_datetime_string_from_system()}
	metrics.reset(0.5)
	metric_opt_orig = 0.0
	metric_opt_sent = 0.0
	metric_opt_saved = 0.0
	client_kills = 0
	client_deaths = 0
	_sent_samples = 0
	# Only the host reports room-level match lifecycle. A guest has its own
	# match clock, and re-reporting MATCH_STARTED would overwrite the host's
	# match_start_time with the guest's skewed value.
	if net_mode != "client":
		monitor_events.append({"type": "MATCH_STARTED", "t": Time.get_ticks_msec() / 1000.0,
			"match_id": match_id, "meta": match_meta.duplicate()})

func _metrics_ctx() -> Dictionary:
	var n := {"bytes_sent": 0, "bytes_received": 0, "pkts_sent": 0, "pkts_recv": 0,
		"ping": -1.0, "rtt": -1.0, "loss": -1.0}
	if net_mode == "host" and net:
		n["bytes_sent"] = net.bytes_sent
		n["bytes_received"] = net.bytes_received
		n["pkts_sent"] = net.packets_sent
		n["pkts_recv"] = net.packets_received
		var rs: Array = []
		var ls: Array = []
		for peer_id in multiplayer.get_peers():
			var r := net.rtt_of(peer_id)
			if r >= 0.0:
				rs.append(r)
			var l := net.loss_of("in:%d" % peer_id)
			if l >= 0.0:
				ls.append(l)
		if not rs.is_empty():
			var s := 0.0
			for v in rs:
				s += v
			n["rtt"] = s / rs.size()
			n["ping"] = s / rs.size()
		if not ls.is_empty():
			var s2 := 0.0
			for v in ls:
				s2 += v
			n["loss"] = s2 / ls.size()
	elif net_mode == "client" and net:
		n["bytes_sent"] = net.bytes_sent
		n["bytes_received"] = net.bytes_received
		n["pkts_sent"] = net.packets_sent
		n["pkts_recv"] = net.packets_received
		var r := net.rtt_of(1)
		n["rtt"] = r
		n["ping"] = r
		n["loss"] = net.loss_of("snap")
	var opt := {"orig": metric_opt_orig, "comp": metric_opt_sent,
		"ratio": -1.0, "comp_us": 0.0, "decomp_us": 0.0,
		"deltas": 0, "fulls": 0, "saved": metric_opt_saved}
	if comm and comm.opt:
		var st: Dictionary = (comm.opt as OptimizedCodec).stats()
		opt["deltas"] = int(st.get("deltas", 0))
		opt["fulls"] = int(st.get("fulls", 0))
		opt["comp_us"] = float(st.get("comp_us", 0))
	if metric_opt_orig > 0.0:
		opt["ratio"] = metric_opt_sent / metric_opt_orig
	if net:
		opt["decomp_us"] = float(net.decomp_us_total)
	var kills := 0
	var deaths := 0
	if net_mode == "client":
		kills = client_kills
		deaths = client_deaths
	else:
		for id in stats:
			kills += int((stats[id] as Dictionary).get("kills", 0))
			deaths += int((stats[id] as Dictionary).get("deaths", 0))
	return {"net": n, "opt": opt, "kills": kills, "deaths": deaths}

## Queue a structured event for the room/session monitor. Events are
## timestamped here (real) and delivered with the next telemetry post.
func _monitor_event(kind: String, data: Dictionary = {}) -> void:
	var ev := {"type": kind, "t": Time.get_ticks_msec() / 1000.0,
		"room_code": my_room_code, "device_id": device_id, "detail": data}
	monitor_events.append(ev)
	# keep the queue bounded: drop the oldest non-critical event if it grows
	if monitor_events.size() > 400:
		monitor_events = monitor_events.slice(-300)

## Telemetry snapshot for the research monitor. Everything here is measured
## in-process; unavailable values are -1 (dashboard shows N/A).
func collect_telemetry() -> Dictionary:
	var ctx := _metrics_ctx()
	var last: Dictionary = metrics.samples.back() if not metrics.samples.is_empty() else {}
	var codec := {}
	var cflags := {}
	if comm and comm.opt:
		var st: Dictionary = (comm.opt as OptimizedCodec).stats()
		codec = st
		cflags = st.get("flags", {})
	var new_samples: Array = []
	if metrics.samples.size() > _sent_samples:
		new_samples = metrics.samples.slice(_sent_samples)
	var evs: Array = monitor_events.duplicate()
	return {
		"type": "METRIC_SAMPLE",
		"src": ("host" if net_mode == "host" else ("client" if net_mode == "client" else "solo")),
		"device_id": device_id, "device_name": device_name,
		"platform": device_platform,
		"room_code": my_room_code,
		"is_host": am_host,
		"room_players": (room_mgr.rooms[my_room_code]["players"].size()
			if (room_mgr != null and my_room_code != "" and room_mgr.rooms.has(my_room_code)) else 0),
		"timestamp": Time.get_ticks_msec() / 1000.0,
		"match_id": match_id, "experiment_id": experiment_id,
		"mode": str(match_meta.get("mode", "IDLE")),
		"source": str(match_meta.get("net", "none")),
		"phase": ["MENU", "COUNTDOWN", "PLAYING", "GAMEOVER"][clampi(phase, 0, 3)],
		"players": combatants.size(),
		# get_peers() throws when no MultiplayerPeer is assigned yet (e.g. a
		# guest before its link is up), so it must be guarded
		"net_peers": (multiplayer.get_peers().size() if multiplayer.multiplayer_peer != null else 0),
		"net_host": net_mode,
		"net_connected": (net.connected if net else false),
		"scores": team_scores.duplicate(), "time_left": time_left,
		"sample": last, "new_samples": new_samples, "events": evs,
		"match_meta": match_meta.duplicate(),
		"net": ctx["net"], "opt": ctx["opt"],
		"codec": codec, "codec_flags": cflags,
		"net_cfg": {"update_hz": net_update_hz, "budget_kbps": net_budget_kbps,
			"budget_skipped": bw_skipped, "budget_sent_bytes": bw_sent_bytes,
			"attempts": bw_attempts, "sent_packets": bw_sent_packets,
			"oversize_dropped": bw_oversize, "max_packet": net_max_packet,
			"effective_hz": (float(bw_sent_packets) / maxf(0.001, metrics.elapsed)),
			"link": ("simulated: " + net_sim.describe()) if (net_sim != null and net_sim.enabled) else "real",
			"sim_stats": (net_sim.stats() if (net_sim != null and net_sim.enabled) else {})},
		"monitor": {"bytes_out": monitor.bytes_out if monitor else 0,
			"bytes_in": monitor.bytes_in if monitor else 0},
	}

## Called by MonitorLink after a successful POST. Only the samples/events
## that were actually in that payload are dropped: anything appended while
## the request was in flight (e.g. MATCH_ENDED) stays queued.
func confirm_telemetry_sent(sent_samples := -1, sent_events := -1) -> void:
	if sent_samples < 0:
		_sent_samples = metrics.samples.size()
	else:
		_sent_samples += sent_samples
	if sent_events < 0:
		monitor_events.clear()
	elif sent_events > 0:
		monitor_events = monitor_events.slice(sent_events)

## Safe dashboard commands. Every branch validates; unknown commands and
## bad values return applied=false with a reason (ACK semantics).
## COMMAND_ACK text. `get(key, fallback)` is useless here because these
## results always carry an EMPTY "error" key on success, which would make
## every successful command ACK a blank string. Fall back on emptiness, and
## describe the EFFECTIVE values so the log is useful.
func _cmd_detail(r: Dictionary, ok_text: String) -> String:
	var err := str(r.get("error", ""))
	if err != "":
		return err
	if r.has("update_hz"):
		var link := str(r.get("sim", "")) if str(r.get("sim", "")) != "" else \
			("link: " + (net_sim.describe() if (net_sim != null and net_sim.enabled) else "real"))
		return "hz=%s budget=%sK max_packet=%s %s" % [
			str(r.get("update_hz")), str(r.get("budget_kbps")),
			str(r.get("max_packet")), link]
	if r.has("config"):
		return "%s %s" % [ok_text, JSON.stringify(r.get("config", {}))]
	return ok_text


func apply_monitor_command(cmd: String, params: Dictionary) -> Dictionary:
	match cmd:
		"ping":
			return {"applied": true, "detail": "pong"}
		"set_opt":
			var r := apply_opt_config(params)
			if bool(r.get("applied", false)):
				monitor_events.append({"type": "CONFIG_APPLIED", "t": Time.get_ticks_msec() / 1000.0,
					"match_id": match_id, "detail": "opt " + JSON.stringify(r.get("config", {}))})
			return {"applied": bool(r.get("applied", false)),
				"detail": _cmd_detail(r, "opt config applied")}
		"set_net":
			var r2 := apply_net_config(params)
			if bool(r2.get("applied", false)):
				monitor_events.append({"type": "CONFIG_APPLIED", "t": Time.get_ticks_msec() / 1000.0,
					"match_id": match_id, "detail": "net hz=%s budget=%s" % [
					str(r2.get("update_hz", "?")), str(r2.get("budget_kbps", "?"))]})
			return {"applied": bool(r2.get("applied", false)),
				"detail": _cmd_detail(r2, "net config applied")}
		"start_metrics":
			metrics_paused = false
			return {"applied": true, "detail": "metrics sampling on"}
		"stop_metrics":
			metrics_paused = true
			return {"applied": true, "detail": "metrics sampling off"}
		"experiment_start":
			experiment_id = str(params.get("experiment_id", ""))
			monitor_events.append({"type": "EXPERIMENT_STARTED", "t": Time.get_ticks_msec() / 1000.0,
				"match_id": match_id, "detail": experiment_id})
			return {"applied": true, "detail": "experiment armed: " + experiment_id}
		"experiment_stop":
			monitor_events.append({"type": "EXPERIMENT_STOPPED", "t": Time.get_ticks_msec() / 1000.0,
				"match_id": match_id, "detail": experiment_id})
			experiment_id = ""
			return {"applied": true, "detail": "experiment disarmed"}
		# ---- held join decisions (dashboard Accept/Reject) ----
		"approve_join":
			return _resolve_join_decision(true, params)
		"reject_join":
			return _resolve_join_decision(false, params)
		# ---- safe game control (host only, state-checked) ----
		"start_match":
			if not am_host:
				return {"applied": false, "owned": false,
					"detail": "only the room host can start the match"}
			if my_room_code == "":
				return {"applied": false, "detail": "no room: create a room first"}
			if phase != Phase.MENU:
				return {"applied": false, "detail": "match already started (phase %d)" % phase}
			_on_room_start()
			return {"applied": true, "detail": "match start requested"}
		"stop_match":
			if not am_host:
				return {"applied": false, "owned": false,
					"detail": "only the room host can stop the match"}
			if phase == Phase.GAMEOVER:
				return {"applied": false, "detail": "match already ended"}
			end_match()
			return {"applied": true, "detail": "match ended by operator"}
		"pause":
			if phase != Phase.PLAYING and not paused:
				return {"applied": false, "detail": "can only pause during PLAYING"}
			toggle_pause(not paused)
			return {"applied": true, "detail": "resumed" if paused else "paused"}
	return {"applied": false, "detail": "unknown command: " + cmd}

func _save_match() -> void:
	if match_id == "":
		return
	# Only the host reports room-level match lifecycle (see begin_metrics).
	if net_mode != "client":
		monitor_events.append({"type": "MATCH_ENDED", "t": Time.get_ticks_msec() / 1000.0,
			"match_id": match_id, "meta": match_meta.duplicate()})
	var summary: Dictionary = metrics.summary(match_meta)
	var res: Dictionary = storage.save_match(match_id, match_meta, metrics.to_csv(), summary)
	last_match_id = match_id
	if bool(res.get("ok", false)):
		print("MATCHDATA: saved ", res.get("path", ""))
	else:
		push_warning("MATCHDATA: save failed: " + str(res.get("error", "?")))

const NET_TICK := 1.0 / 20.0
# ---- dashboard-driven network controls (all enforced, all measured) ----
var net_update_hz := 20.0 # snapshot rate, validated 5..60
var net_budget_kbps := 0.0 # 0 = unlimited; token-bucket budget on snapshots
var net_max_packet := 0 # 0 = unlimited; oversized snapshots are not sent
var _bw_tokens := 0.0 # accrued budget bytes
var bw_skipped := 0 # snapshots dropped by the budget (measured cost)
var bw_sent_bytes := 0 # snapshots actually broadcast (measured actual)
var bw_attempts := 0 # snapshots the encoder produced
var bw_sent_packets := 0 # snapshots that actually left the host
var bw_oversize := 0 # snapshots rejected by the max-packet-size cap
# When the budget is the binding constraint, bytes saturate at the same
# ceiling for every codec: the meaningful axis is how much FRESH state got
# through, i.e. effective update rate = bw_sent_packets / elapsed.
# Optional SIMULATED link conditioner (research only). null/disabled in
# normal play: snapshots then take the identical direct path as before.
var net_sim: NetSim = null

func _ensure_net() -> NetTransport:
	if net == null:
		net = NetTransport.new()
		net.name = "NetTransport"
		add_child(net)
		net.peer_joined.connect(_on_net_peer_joined)
		net.peer_left.connect(_on_net_peer_left)
		net.hello_received.connect(_on_net_hello)
		net.input_received.connect(_on_net_input)
		net.fire_received.connect(_on_net_fire)
		net.pickup_received.connect(_on_net_pickup)
		net.ready_received.connect(_on_net_ready)
		net.snapshot_received.connect(_on_net_snapshot)
		net.event_received.connect(_on_net_event)
		net.lobby_received.connect(_on_net_lobby)
		net.welcome_received.connect(_on_net_welcome)
		net.starting_received.connect(_on_net_starting)
		net.shot_received.connect(_on_net_shot)
	return net

func _teardown_net() -> void:
	net_mode = ""
	my_net_id = -1
	peer_pid.clear()
	combatant_peer.clear()
	last_fire_msec.clear()
	for k in puppets:
		if is_instance_valid(puppets[k]):
			puppets[k].queue_free()
	puppets.clear()
	puppet_wid.clear()
	net_boxes.clear()
	net_room = {}
	pending_code = ""
	if net:
		net.close()

# ---------------- host ----------------
func _net_has_guests() -> bool:
	if net == null or not net.connected or not net.is_host:
		return false
	return not multiplayer.get_peers().is_empty()

func _broadcast_lobby() -> void:
	if net_mode == "host" and net:
		var room := room_mgr.get_room(my_room_code)
		if not room.is_empty():
			net.send_lobby(room)

func start_net_host() -> void:
	var room := room_mgr.get_room(my_room_code)
	if room.is_empty():
		return
	room_mgr.lock_room(my_room_code)
	room_mgr.set_state(my_room_code, "PLAYING")
	# tell remote lobby guests to build their client worlds
	for peer_id in multiplayer.get_peers():
		var gpid := str(peer_pid.get(peer_id, ""))
		var gcid := -1
		var gteam := 1
		for pl in room["players"]:
			if str((pl as Dictionary).get("pid", "")) == gpid:
				gcid = int((pl as Dictionary).get("cid", -1))
				gteam = int((pl as Dictionary).get("team", 1))
		net.send_starting(peer_id, {"proto": 1, "seed": int(room["map_seed"]),
			"mode": str(room["mode"]), "code": my_room_code, "cid": gcid, "team": gteam})
	net_mode = "host"
	comm = CommManager.make(str(room.get("mode", "NORMAL")))
	net.comm = comm
	begin_metrics("NET-" + str(room.get("mode", "NORMAL")), my_room_code,
		int(room.get("map_seed", 0)), room_mgr.human_count(room),
		(room["players"] as Array).size() - room_mgr.human_count(room), "real")
	_rebuild_arena(int(room.get("map_seed", 0)))
	team_scores = [0, 0]
	stats.clear()
	dead_timers.clear()
	time_left = ArenaConfig.MATCH_TIME_SEC
	# host body (cid 0)
	player = PlayerController.new()
	player.is_human = true
	player.setup(0, int(_room_team(room, my_pid)), settings.avatar_id,
		_room_name(room, my_pid), Callable(self, "deal_damage"), fx)
	player.get_combatants = func() -> Array: return combatants
	player.skin_id = settings.skin_id
	fighters.add_child(player)
	_register(player)
	# remote humans as server-side bodies
	for pl in room["players"]:
		var d: Dictionary = pl
		if bool(d.get("is_bot", false)) or bool(d.get("is_host", false)):
			continue
		var cid := int(d.get("cid", -1))
		var bpeer := _peer_of_pid(str(d.get("pid", "")))
		if cid < 0 or bpeer < 0:
			continue
		var rb := PlayerController.new()
		rb.is_human = false
		rb.net_controlled = true
		rb.input_provider = GameInput.Net.new()
		rb.setup(cid, int(d.get("team", 1)), int(d.get("avatar_id", 0)),
			str(d.get("name", "?")), Callable(self, "deal_damage"), fx)
		rb.get_combatants = func() -> Array: return combatants
		fighters.add_child(rb)
		_register(rb)
		combatant_peer[cid] = bpeer
	# bots fill the rest
	_fill_bots_net(room)
	_index_boxes()
	for c in combatants:
		c.respawn_at(_spawn_pos(c.team_id, c.player_id), _spawn_yaw(c.team_id))
		c.set_physics_process(false)
	phase = Phase.COUNTDOWN
	countdown = ArenaConfig.COUNTDOWN_SEC
	paused = false
	menus.hide_all()
	hud.visible = true
	hud.bind(player)
	hud.show_respawn(0.0)
	player.camera.current = true
	_assign_player_input()
	if touch_active():
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _room_team(room: Dictionary, pid: String) -> int:
	for pl in room["players"]:
		if str(pl["pid"]) == pid:
			return int(pl["team"])
	return 0

func _room_name(room: Dictionary, pid: String) -> String:
	for pl in room["players"]:
		if str(pl["pid"]) == pid:
			return str(pl["name"])
	return "?"

func _peer_of_pid(pid: String) -> int:
	for peer_id in peer_pid:
		if str(peer_pid[peer_id]) == pid:
			return int(peer_id)
	return -1

func _fill_bots_net(room: Dictionary) -> void:
	var used := combatants.size()
	var bi := 0
	while combatants.size() < RoomManager.MAX_PLAYERS:
		var cid: int = used + bi
		var bteam := 0 if (combatants.filter(func(c) -> bool: return c.team_id == 0).size()
			<= combatants.filter(func(c) -> bool: return c.team_id == 1).size()) else 1
		var bot := BotController.new()
		bot.setup(cid, bteam, (cid + 1) % AvatarDB.count(),
			BOT_NAMES[cid % BOT_NAMES.size()] + " (bot)",
			Callable(self, "visible_enemies_for"), Callable(self, "deal_damage"),
			fx, covers, _spawn_pos(bteam, cid), randf_range(0.35, 0.8))
		fighters.add_child(bot)
		_register(bot)
		bot.combatants = combatants
		if bot.weapon:
			bot.weapon.auto_reload = true
		bi += 1
		if bi > 16:
			break

func _rebuild_arena(map_seed: int) -> void:
	for c in arena.get_children():
		c.queue_free()
	for c in fighters.get_children():
		c.queue_free()
	_clear_fighters()
	var built: Dictionary = ArenaBuilder.build(arena, map_seed)
	covers = built["covers"]
	spawns["blue"] = built["spawns_blue"]
	spawns["red"] = built["spawns_red"]

func _index_boxes() -> void:
	net_boxes = get_tree().get_nodes_in_group("pickup")
	for i in net_boxes.size():
		(net_boxes[i] as PickupItem).box_index = i

func _host_broadcast(dt: float) -> void:
	broadcast_acc += dt
	var tick := 1.0 / clampf(net_update_hz, 5.0, 60.0)
	if broadcast_acc < tick:
		return
	broadcast_acc = 0.0
	var states: Array = []
	for c in combatants:
		if is_instance_valid(c) and c.has_method("snapshot"):
			var s: Dictionary = c.snapshot()
			# shooting flag for server bodies: recent validated fire
			if last_fire_msec.has(c.player_id):
				s["shooting"] = Time.get_ticks_msec() - int(last_fire_msec[c.player_id]) < 150
			states.append(s)
	snap_seq += 1
	bw_attempts += 1
	var enc: Dictionary = comm.encode_snapshot(states, team_scores, time_left, snap_seq)
	var nbytes := int(enc.get("transferred_bytes", 0))
	# max packet size: no fragmentation is performed (a split snapshot would
	# break the receiver's delta base), so oversized snapshots are refused
	# and counted instead of being silently truncated
	if net_max_packet > 0 and nbytes > net_max_packet:
		bw_oversize += 1
		return
	# bandwidth budget: token bucket; over-budget snapshots are dropped
	# (counted) so Allowed-vs-Actual graphs show the real constraint cost
	if net_budget_kbps > 0.0:
		_bw_tokens = minf(net_budget_kbps * 1000.0 / 8.0,
			_bw_tokens + net_budget_kbps * 1000.0 / 8.0 * dt)
		if _bw_tokens < float(nbytes):
			bw_skipped += 1
			return
		_bw_tokens -= float(nbytes)
	metric_opt_orig += float(enc.get("original_bytes", 0))
	metric_opt_sent += float(nbytes)
	metric_opt_saved += float(enc.get("original_bytes", 0)) - float(nbytes)
	bw_sent_bytes += nbytes
	bw_sent_packets += 1
	if net_sim != null and net_sim.enabled:
		# SIMULATED link: delay/jitter/loss/bandwidth shape the packet.
		# Labeled 'simulated' in match metadata so real/sim never mix.
		net_sim.send("snapshot", enc, nbytes, func(_k: String, _p: Variant) -> void:
			net.broadcast_snapshot(enc))
		if net_sim.bw_kbps <= 0.0:
			net_sim.bw_kbps = net_budget_kbps # reuse the budget as link speed
	else:
		net.broadcast_snapshot(enc)
	if net_sim != null and net_sim.enabled:
		net_sim.update()

## Current link-conditioner state, for honest before/after config diffs.
func net_sim_state() -> Dictionary:
	if net_sim == null or not net_sim.enabled:
		return {"enabled": false, "latency_ms": 0.0, "jitter_ms": 0.0,
			"loss_pct": 0.0, "bw_kbps": 0.0}
	return {"enabled": true, "latency_ms": net_sim.latency_ms,
		"jitter_ms": net_sim.jitter_ms, "loss_pct": net_sim.loss_pct,
		"bw_kbps": net_sim.bw_kbps}

## Validated network config from the dashboard. Returns effective values;
## anything invalid is rejected with a reason (for COMMAND_ACK semantics).
##
## Covers BOTH the real send path (update rate, token-bucket budget, max
## packet size) and the simulated link conditioner (latency/jitter/loss/sim
## bandwidth), so every control the dashboard exposes is actually applied.
func apply_net_config(d: Dictionary) -> Dictionary:
	var res := {"update_hz": net_update_hz, "budget_kbps": net_budget_kbps,
		"max_packet": net_max_packet, "applied": true, "error": ""}
	# snapshot BEFORE mutating, otherwise every diff compares a value with
	# itself and silently reports "no change".
	var old := {"update_hz": net_update_hz, "budget_kbps": net_budget_kbps,
		"max_packet": net_max_packet, "sim": net_sim_state()}
	if d.has("update_hz"):
		var hz := float(d["update_hz"])
		if hz < 5.0 or hz > 60.0:
			res["applied"] = false
			res["error"] = "update_hz %.1f out of range 5..60" % hz
			return res
		net_update_hz = hz
	if d.has("budget_kbps"):
		var b := float(d["budget_kbps"])
		if b < 0.0 or b > 100000.0:
			res["applied"] = false
			res["error"] = "budget_kbps %.1f out of range 0..100000" % b
			return res
		net_budget_kbps = b
		_bw_tokens = minf(_bw_tokens, b * 1000.0 / 8.0) if b > 0.0 else 0.0
	if d.has("max_packet"):
		var mp := int(d["max_packet"])
		if mp != 0 and (mp < 256 or mp > 1048576):
			res["applied"] = false
			res["error"] = "max_packet %d out of range 256..1048576 (0 = unlimited)" % mp
			return res
		net_max_packet = mp

	# simulated link conditioner (latency/jitter/loss/sim_bw). Keys are read
	# from the CURRENT state so a partial command only overrides what it names.
	if d.has("latency_ms") or d.has("jitter_ms") or d.has("loss_pct") \
			or d.has("sim_bw_kbps"):
		var cur := net_sim_state()
		var lat := float(d.get("latency_ms", cur["latency_ms"]))
		var jit := float(d.get("jitter_ms", cur["jitter_ms"]))
		var loss := float(d.get("loss_pct", cur["loss_pct"]))
		var sim_bw := float(d.get("sim_bw_kbps", cur["bw_kbps"]))
		var sr := configure_net_sim(lat, jit, loss, sim_bw)
		if not bool(sr.get("applied", false)):
			res["applied"] = false
			res["error"] = str(sr.get("error", "link conditioner rejected values"))
			return res
		res["sim"] = str(sr.get("detail", ""))

	var changes := {}
	if absf(float(old["update_hz"]) - net_update_hz) > 0.01:
		changes["update_hz"] = {"from": old["update_hz"], "to": net_update_hz}
	if absf(float(old["budget_kbps"]) - net_budget_kbps) > 0.01:
		changes["budget_kbps"] = {"from": old["budget_kbps"], "to": net_budget_kbps}
	if int(old["max_packet"]) != net_max_packet:
		changes["max_packet"] = {"from": old["max_packet"], "to": net_max_packet}
	var after := net_sim_state()
	if JSON.stringify(old["sim"]) != JSON.stringify(after):
		changes["simulated"] = {"from": old["sim"], "to": after}
	res["update_hz"] = net_update_hz
	res["budget_kbps"] = net_budget_kbps
	res["max_packet"] = net_max_packet
	if not changes.is_empty():
		_monitor_event("NETWORK_CONFIG_CHANGED", {"changes": changes})
	return res

## Validated SIMULATED link configuration (research runs). Rejects
## impossible values; returns the effective description. Passing all-zero
## disables the conditioner and restores the direct path.
func configure_net_sim(latency_ms: float, jitter_ms: float, loss_pct: float,
		bw_kbps: float = 0.0) -> Dictionary:
	for name_v in [["latency_ms", latency_ms, 0.0, 5000.0],
			["jitter_ms", jitter_ms, 0.0, 5000.0],
			["loss_pct", loss_pct, 0.0, 100.0],
			["bw_kbps", bw_kbps, 0.0, 100000.0]]:
		var v := float(name_v[1])
		if v < float(name_v[2]) or v > float(name_v[3]):
			return {"applied": false, "error": "%s=%s out of range %s..%s" % [
				str(name_v[0]), str(v), str(name_v[2]), str(name_v[3])]}
	if latency_ms <= 0.0 and jitter_ms <= 0.0 and loss_pct <= 0.0 and bw_kbps <= 0.0:
		net_sim = null
		match_meta["net"] = "real"
		return {"applied": true, "enabled": false, "detail": "link conditioner off"}
	if net_sim == null:
		net_sim = NetSim.new() # RefCounted: driven manually, no tree node
	net_sim.configure(latency_ms, jitter_ms, loss_pct, bw_kbps)
	match_meta["net"] = "simulated"
	_monitor_event("NETWORK_CONFIG_CHANGED", {"changes": {
		"simulated": {"from": "real", "to": net_sim.describe()}}})
	return {"applied": true, "enabled": true, "detail": net_sim.describe()}

## Validated codec config from the dashboard (host side).
func apply_opt_config(d: Dictionary) -> Dictionary:
	if comm == null or comm.opt == null:
		return {"applied": false, "error": "no active optimized codec (start an OPTIMIZED match first)"}
	var before: Dictionary = (comm.opt as OptimizedCodec).get_config()
	var eff: Dictionary = (comm.opt as OptimizedCodec).apply_config(d)
	var changes := {}
	for k in eff:
		if str(before.get(k, "")) != str(eff.get(k, "")):
			changes[str(k)] = {"from": before.get(k), "to": eff.get(k)}
	_monitor_event("OPTIMIZATION_CHANGED", {"changes": changes, "config": eff})
	return {"applied": true, "error": "", "config": eff}

# ---------------- host RPC handlers ----------------
func _on_net_peer_joined(peer_id: int) -> void:
	if net_mode != "host":
		return
	# lobby-stage guests are handled at hello; in-match joins are rejected
	pass

func _on_net_hello(peer_id: int, hello: Dictionary) -> void:
	if not am_host and net_mode != "host":
		return
	var code := str(hello.get("code", ""))
	var room := room_mgr.get_room(code) if code == my_room_code else {}
	if room.is_empty() or str(room.get("state", "")) != "LOBBY":
		net.send_welcome(peer_id, {"proto": 1, "ok": false,
			"error": "Room not found" if room.is_empty() else "Match already started"})
		return
	if (room["players"] as Array).size() >= int(room["max_players"]):
		net.send_welcome(peer_id, {"proto": 1, "ok": false, "error": "Room is full"})
		return
	# Hold for approval: the join is registered on the dashboard where the
	# host accepts/rejects it (or it auto-approves after PENDING_TIMEOUT).
	if settings.approve_joins:
		if pending_joins.has(peer_id):
			return # duplicate hello; already holding this one
		_hold_join(peer_id, hello, code, room)
		return
	_accept_join(peer_id, hello, code, room)

## Approval path: park the join, tell the monitor, let the dashboard decide.
func _hold_join(peer_id: int, hello: Dictionary, code: String, room: Dictionary) -> void:
	var players := (room["players"] as Array).size()
	var maxp := int(room["max_players"])
	pending_joins[peer_id] = {"hello": hello, "code": code,
		"t": Time.get_ticks_msec() / 1000.0}
	var who := str(hello.get("name", "Guest"))
	if monitor:
		monitor.post_aux("/api/rooms/%s/pending" % code, {
			"peer": peer_id, "name": who, "avatar": int(hello.get("avatar", 0)),
			"device": str(hello.get("device", "")),
			"device_name": str(hello.get("device_name", "")),
			"platform": str(hello.get("platform", "")),
			"players": players, "max_players": maxp, "approver": device_id})
	if join_alerts:
		var res := JoinNotifier.notify_join(who, code, players, maxp, dashboard_url(code))
		join_banner_text = "%s wants to join  ·  room %s  ·  %d/%d" % [
			who, code, players, maxp]
		join_banner_t = 6.0
		if hud:
			hud.show_join_banner(join_banner_text, join_banner_t)
		print("JOIN-HOLD: ", JSON.stringify(res))

## Dashboard link the join notification opens (deep-links the room view).
func dashboard_url(code: String) -> String:
	if monitor == null:
		return ""
	return monitor.base_url.rstrip("/") + "/#room/" + code

## Admission path (approval off, or a held join the host accepted).
func _accept_join(peer_id: int, hello: Dictionary, code: String, room: Dictionary,
		suppress_alert := false) -> bool:
	if room.is_empty() or str(room.get("state", "")) != "LOBBY":
		net.send_welcome(peer_id, {"proto": 1, "ok": false,
			"error": "Room not found" if room.is_empty() else "Match already started"})
		return false
	if (room["players"] as Array).size() >= int(room["max_players"]):
		net.send_welcome(peer_id, {"proto": 1, "ok": false, "error": "Room is full"})
		return false
	var entry := room_mgr._add_player(room, str(hello.get("name", "Guest")),
		int(hello.get("avatar", 0)), false, false)
	var cid := _free_cid(room)
	entry["cid"] = cid
	peer_pid[peer_id] = entry["pid"]
	last_fire_msec[cid] = 0
	_monitor_event("ROOM_JOINED", {
		"room_code": code, "player_id": cid, "name": str(hello.get("name", "Guest")),
		"device_id": str(hello.get("device", "unknown")),
		"device_name": str(hello.get("device_name", "unknown")),
		"platform": str(hello.get("platform", "unknown")),
		"team": int(entry["team"])})
	net.send_welcome(peer_id, {"proto": 1, "ok": true, "cid": cid,
		"team": int(entry["team"]), "seed": int(room["map_seed"]),
		"mode": str(room["mode"]), "code": code, "players": room["players"]})
	_broadcast_lobby()
	# Host PC alert: someone wants in. Desktop notification + beep + banner.
	# (Skipped for held joins: _hold_join already raised it at knock time.)
	if join_alerts and not suppress_alert:
		var who := str(hello.get("name", "Guest"))
		var res := JoinNotifier.notify_join(who, code,
			(room["players"] as Array).size(), int(room["max_players"]),
			dashboard_url(code))
		join_banner_text = "%s joined  ·  room %s  ·  %d/%d" % [
			who, code, (room["players"] as Array).size(), int(room["max_players"])]
		join_banner_t = 6.0
		if hud:
			hud.show_join_banner(join_banner_text, join_banner_t)
		print("JOIN-NOTIFY: ", JSON.stringify(res))
	return true

## Decide a held join (dashboard Accept/Reject arrives as a monitor command).
func _resolve_join_decision(approve: bool, params: Dictionary) -> Dictionary:
	var pid := int(params.get("peer", -1))
	var code := str(params.get("code", ""))
	if not am_host:
		return {"applied": false, "owned": false, "detail": "not the host"}
	if code != "" and code != my_room_code:
		return {"applied": false, "owned": false, "detail": "another room's join"}
	if not pending_joins.has(pid):
		# already auto-resolved (or never held): clear the row, no repeat action
		if code != "":
			_resolve_monitor(code, pid)
		return {"applied": true, "detail": "no held join for that peer"}
	var p: Dictionary = pending_joins[pid]
	pending_joins.erase(pid)
	var held_code := str(p.get("code", code))
	var room := room_mgr.get_room(held_code) if room_mgr else {}
	var who := str((p.get("hello", {}) as Dictionary).get("name", "Guest"))
	var done := false
	if approve:
		done = _accept_join(pid, p.get("hello", {}) as Dictionary, held_code, room, true)
		if not done:
			_resolve_monitor(held_code, pid)
			return {"applied": true, "detail": "room no longer joinable"}
	else:
		if net:
			net.send_welcome(pid, {"proto": 1, "ok": false,
				"error": "Join request rejected by the host"})
		_monitor_event("JOIN_REJECTED", {"room_code": held_code, "name": who})
	_resolve_monitor(held_code, pid)
	return {"applied": true, "detail": "%s %s" % [
		"approved" if approve else "rejected", who]}

## Tell the monitor a held join is finished from our side (decision applied,
## auto-approved, or the peer vanished). The dashboard only lists rows that
## still need attention, so these clear off the panel.
func _resolve_monitor(code: String, peer_id: int) -> void:
	if monitor == null or code == "":
		return
	monitor.post_aux("/api/pending/resolve",
		{"code": code, "peer": peer_id, "status": "done"})

## Held-join watchdog: reaped on every physics tick (host only).
func _pending_tick() -> void:
	if join_alerts != settings.join_alerts:
		join_alerts = settings.join_alerts
	if pending_joins.is_empty():
		return
	var now := Time.get_ticks_msec() / 1000.0
	var todo: Array = []
	for peer_id in pending_joins:
		var p: Dictionary = pending_joins[peer_id]
		if now - float(p.get("t", now)) >= PENDING_TIMEOUT:
			todo.append(peer_id)
	for peer_id in todo:
		var p: Dictionary = pending_joins[peer_id]
		pending_joins.erase(peer_id)
		var code := str(p.get("code", ""))
		var room := room_mgr.get_room(code) if room_mgr else {}
		var ok := not room.is_empty() and str(room.get("state", "")) == "LOBBY" \
			and (room["players"] as Array).size() < int(room["max_players"])
		if ok and _accept_join(peer_id, p.get("hello", {}) as Dictionary, code, room, true):
			_resolve_monitor(code, peer_id)
			print("JOIN-AUTO: approved after %.0fs" % PENDING_TIMEOUT)
		else:
			if net:
				net.send_welcome(peer_id, {"proto": 1, "ok": false,
					"error": "Room not available"})
			_resolve_monitor(code, peer_id)
			print("JOIN-AUTO: dropped (room gone)")

func _free_cid(room: Dictionary) -> int:
	var used := {0: true}
	for pl in room["players"]:
		if (pl as Dictionary).has("cid"):
			used[int(pl["cid"])] = true
	for i in range(1, RoomManager.MAX_PLAYERS):
		if not used.has(i):
			return i
	return -1

func _on_net_input(peer_id: int, inp: Dictionary) -> void:
	if net_mode != "host":
		return
	var cid := _cid_of_peer(peer_id)
	var body := _by_id(cid) if cid >= 0 else null
	if body == null or not (body is PlayerController):
		return
	var prov: GameInput.Net = (body as PlayerController).input_provider
	if prov == null or not (prov is GameInput.Net):
		return
	var mv: Array = inp.get("move", [0, 0])
	var lk: Array = inp.get("look", [0, 0])
	prov.feed(Vector2(float(mv[0]), float(mv[1])),
		Vector2(float(lk[0]), float(lk[1])),
		inp.get("held", {}), inp.get("pressed", []))

func _cid_of_peer(peer_id: int) -> int:
	var pid := str(peer_pid.get(peer_id, ""))
	var room := room_mgr.get_room(my_room_code)
	if room.is_empty():
		return -1
	for pl in room["players"]:
		if str(pl["pid"]) == pid:
			return int((pl as Dictionary).get("cid", -1))
	return -1

func _on_net_fire(peer_id: int, d: Dictionary) -> void:
	if net_mode != "host" or phase != Phase.PLAYING:
		return
	var cid := _cid_of_peer(peer_id)
	var body := _by_id(cid) if cid >= 0 else null
	if body == null or not (body is PlayerController) or bool(body.get("dead")):
		return
	var pb: PlayerController = body
	var wid := int(d.get("weapon", -1))
	if pb.weapon == null or pb.weapon.weapon_id() != wid:
		return
	# rate validation (20% margin over weapon rate)
	var now := Time.get_ticks_msec()
	var min_gap := 1000.0 / float(pb.weapon.data["fire_rate"]) * 0.8
	if now - int(last_fire_msec.get(cid, 0)) < int(min_gap):
		return
	# origin must be near the server body (4m tolerance for interp/lag)
	var org := _v3(d.get("origin", Vector3.ZERO))
	var chest: Vector3 = (body as Node3D).global_position + Vector3(0, 1.4, 0)
	if org.distance_to(chest) > 4.0:
		return
	var dir := _v3(d.get("dir", Vector3.FORWARD))
	if dir.length() < 0.5:
		return
	dir = dir.normalized()
	var before: int = pb.weapon.mag
	var shots: Array = []
	pb.weapon.trigger_held = true
	var space := (body as Node3D).get_world_3d().direct_space_state
	var mz := _body_muzzle(body)
	# ADS shots from the guest get the same tighter cone as local ADS fire
	var spread_mult := 1.0
	var aprov: GameInput = pb.input_provider
	if aprov is GameInput.Net and bool((aprov as GameInput.Net).held.get("aim", false)):
		spread_mult = 0.55
	pb.weapon.try_fire(space, org, dir, cid, Callable(self, "deal_damage"),
		func(a: Vector3, b: Vector3) -> void:
			FX.tracer(fx, mz, b)
			shots.append([mz, b]),
		spread_mult)
	pb.weapon.trigger_held = false
	if pb.weapon.mag != before:
		last_fire_msec[cid] = now
		FX.muzzle(pb.viewmodel)
		FX.shell(fx, mz, (body as Node3D).global_transform.basis.x)
		net.send_shot({"proto": 1, "shooter": cid, "shots": shots})

func _body_muzzle(body: Node) -> Vector3:
	var tp: Node3D = body.get("tp_gun")
	if tp:
		var mz: Node3D = tp.get_node_or_null("Muzzle") as Node3D
		if mz:
			return mz.global_position
	return (body as Node3D).global_position + Vector3(0, 1.4, 0)

func _on_net_pickup(peer_id: int, req: Dictionary) -> void:
	if net_mode != "host" or phase != Phase.PLAYING:
		return
	var cid := _cid_of_peer(peer_id)
	var body := _by_id(cid) if cid >= 0 else null
	var idx := int(req.get("box", -1))
	if body == null or bool(body.get("dead")) or idx < 0 or idx >= net_boxes.size():
		return
	var box: PickupItem = net_boxes[idx]
	if box._taken:
		return
	if (body as Node3D).global_position.distance_to(box.global_position) > 3.5:
		return
	(body as Node).pickup_ammo(box.weapon_key, box.amount)
	box.take_local()
	net.send_event({"proto": 1, "kind": "pickup", "pid": cid,
		"box": idx, "key": box.weapon_key, "amt": box.amount})

func _on_net_ready(peer_id: int) -> void:
	if not am_host and net_mode != "host":
		return
	var pid := str(peer_pid.get(peer_id, ""))
	if pid != "" and room_mgr.set_ready(my_room_code, pid, true):
		_broadcast_lobby()

func _on_net_peer_left(peer_id: int) -> void:
	if am_host:
		if pending_joins.has(peer_id):
			var held: Dictionary = pending_joins[peer_id]
			pending_joins.erase(peer_id)
			_resolve_monitor(str(held.get("code", "")), peer_id)
		var pid := str(peer_pid.get(peer_id, ""))
		peer_pid.erase(peer_id)
		if pid == "":
			return
		var cid := _cid_of_peer(peer_id)
		var body := _by_id(cid) if cid >= 0 else null
		if body:
			combatants.erase(body)
			body.queue_free()
		combatant_peer.erase(cid)
		# capture identity BEFORE remove_player(), otherwise the lookup
		# returns blank and the session records an anonymous departure
		var gone_name := str(room_mgr.human_name(my_room_code, pid) if room_mgr else "")
		var gone_device := str(room_mgr.device_of(my_room_code, pid) if room_mgr else "")
		room_mgr.remove_player(my_room_code, pid)
		_monitor_event("ROOM_LEFT", {
			"room_code": my_room_code, "player_id": cid,
			"name": gone_name if gone_name != "" else "player",
			"device_id": gone_device if gone_device != "" else "unknown"})
		net.send_event({"proto": 1, "kind": "left",
			"pid": cid, "name": "player"})
		_broadcast_lobby()
	elif net_mode == "client" and peer_id == 1:
		to_menu() # host gone: back to menu (no fake continuity)

static func _v3(v: Variant) -> Vector3:
	if v is Vector3:
		return v
	if v is Array and (v as Array).size() >= 3:
		return Vector3(float(v[0]), float(v[1]), float(v[2]))
	return Vector3.ZERO

# ---------------- client ----------------
func start_net_client(info: Dictionary) -> void:
	net_mode = "client"
	comm = CommManager.make(str(info.get("mode", "NORMAL")))
	net.comm = comm
	my_net_id = int(info.get("cid", 0))
	var humans := 1
	var bots := 7
	if net_room.has("players"):
		humans = 0
		for pl in net_room["players"]:
			if not bool((pl as Dictionary).get("is_bot", false)):
				humans += 1
		bots = (net_room["players"] as Array).size() - humans
	begin_metrics("NET-" + str(info.get("mode", "NORMAL")) + "-client",
		str(info.get("code", "")), int(info.get("seed", 0)), humans, bots, "real")
	_rebuild_arena(int(info.get("seed", 0)))
	team_scores = [0, 0]
	stats.clear()
	dead_timers.clear()
	time_left = ArenaConfig.MATCH_TIME_SEC
	client_respawn_left = 0.0
	player = PlayerController.new()
	player.is_human = true
	player.setup(my_net_id, int(info.get("team", 0)), settings.avatar_id,
		settings.player_name, Callable(self, "deal_damage_fx"), fx)
	player.get_combatants = func() -> Array: return []
	player.skin_id = settings.skin_id
	fighters.add_child(player)
	player.respawn_at(_spawn_pos(player.team_id, my_net_id), _spawn_yaw(player.team_id))
	player.set_physics_process(false)
	get_tree().call_group("pickup", "queue_free")
	PickupItem.spawn_random(arena, 12, covers)
	_index_boxes()
	for b in net_boxes:
		(b as PickupItem).net_client = true
		(b as PickupItem).net_send = Callable(self, "_send_pickup_request")
	phase = Phase.COUNTDOWN
	countdown = ArenaConfig.COUNTDOWN_SEC
	paused = false
	menus.hide_all()
	hud.visible = true
	hud.bind(player)
	hud.show_respawn(0.0)
	player.camera.current = true
	_assign_player_input()
	if touch_active():
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

## Client cosmetic damage path: FX only, zero state change.
func deal_damage_fx(_target: Node, _dmg: float, _shooter: int, _hs: bool, pos: Vector3, normal: Vector3, surface := "dust") -> void:
	if phase != Phase.PLAYING:
		return
	FX.impact(fx, pos, normal, false, surface)

func _send_pickup_request(box_idx: int) -> void:
	if net and net.connected:
		net.send_pickup({"proto": 1, "box": box_idx})

func _client_send_input() -> void:
	input_acc += get_physics_process_delta_time()
	if input_acc < NET_TICK:
		return
	input_acc = 0.0
	input_seq += 1
	var mv := player.input_provider.get_move()
	var held := {"fire": player.input_provider.pressed("fire"),
		"aim": player.input_provider.pressed("aim")}
	var pressed: Array = []
	for a in ["jump", "crouch", "prone", "sprint", "reload", "ability",
			"weapon_1", "weapon_2", "weapon_3", "weapon_cycle"]:
		if player.input_provider.just_pressed(a):
			pressed.append(a)
	net.send_input({"proto": 1, "seq": input_seq,
		"move": [mv.x, mv.y], "look": [player.yaw, player.pitch],
		"held": held, "pressed": pressed, "t": Time.get_ticks_msec() / 1000.0})

func _client_wire_weapon() -> void:
	if player.weapon != client_wired_weapon:
		client_wired_weapon = player.weapon
		if client_wired_weapon:
			client_wired_weapon.fired.connect(_on_client_fired)

func _on_client_fired() -> void:
	if net_mode != "client" or net == null or player == null or player.weapon == null:
		return
	net.send_fire({"proto": 1, "origin": client_aim_from, "dir": client_aim_dir,
		"weapon": player.weapon.weapon_id()})

func _on_net_snapshot(snap: Dictionary, wire_bytes: int) -> void:
	if net_mode != "client":
		return
	if bool(snap.get("repeat", false)):
		# nothing changed: refresh clock/scores only, puppets hold pose
		last_snap_time = float(snap.get("time_left", last_snap_time))
		last_snap_scores = (snap.get("scores", last_snap_scores) as Array).duplicate()
		hud.set_match(last_snap_time, int(last_snap_scores[0]), int(last_snap_scores[1]))
		return
	# clock offset smoothing (server_t - local_t)
	var rtt := net.rtt_of(1)
	var off := float(snap.get("t", 0.0)) - Time.get_ticks_msec() / 1000.0
	if rtt > 0.0:
		off += rtt / 2000.0
	clock_offset = clock_offset * 0.9 + off * 0.1
	last_snap_time = float(snap.get("time_left", last_snap_time))
	last_snap_scores = (snap.get("scores", last_snap_scores) as Array).duplicate()
	hud.set_match(last_snap_time, int(last_snap_scores[0]), int(last_snap_scores[1]))
	var now := Time.get_ticks_msec() / 1000.0 + clock_offset
	var seen := {}
	for s in snap.get("players", []):
		var st: Dictionary = s
		var cid := int(st.get("player_id", -1))
		if cid < 0:
			continue
		seen[cid] = true
		if cid == my_net_id:
			_client_apply_self(st)
		else:
			var pup: RemotePuppet = puppets.get(cid)
			if pup == null or not is_instance_valid(pup):
				pup = RemotePuppet.new()
				pup.setup(cid, int(st.get("team_id", 1)), int(st.get("avatar_id", 0)), str(st.get("name", "?")))
				fighters.add_child(pup)
				puppets[cid] = pup
				puppet_wid[cid] = -1
			if int(st.get("weapon_id", 0)) != int(puppet_wid.get(cid, -1)):
				puppet_wid[cid] = int(st.get("weapon_id", 0))
				pup.set_weapon(int(st.get("weapon_id", 0)))
			pup.apply_snapshot(st, now)
	# drop puppets that vanished (disconnects)
	for cid in puppets.keys():
		if not seen.has(cid):
			if is_instance_valid(puppets[cid]):
				puppets[cid].queue_free()
			puppets.erase(cid)

func _client_apply_self(st: Dictionary) -> void:
	if player == null:
		return
	var hp := float(st.get("health", 100.0))
	var was_dead := player.dead
	var now_dead := hp <= 0.0
	player.health.hp = hp
	player.health.max_hp = maxf(player.health.max_hp, hp)
	player.health.changed.emit(player.health.hp, player.health.max_hp)
	if now_dead and not was_dead:
		player.dead = true
		player._death_t = 0.0
		if player.weapon:
			player.weapon.trigger_held = false
		client_respawn_left = ArenaConfig.RESPAWN_SEC
		hud.show_respawn(client_respawn_left)
	if player.weapon:
		player.weapon.mag = int(st.get("mag", player.weapon.mag)) if st.has("mag") else player.weapon.mag
		player.weapon.reserve = int(st.get("reserve", player.weapon.reserve)) if st.has("reserve") else player.weapon.reserve
	# server position wins on big drift, else keep prediction
	var sp := RemotePuppet._v3(st.get("position", player.global_position))
	if player.global_position.distance_to(sp) > 2.5 and not player.dead:
		player.global_position = sp
		player.velocity = RemotePuppet._v3(st.get("velocity", Vector3.ZERO)) * 0.5

func _client_driver(dt: float) -> void:
	if client_respawn_left > 0.0:
		client_respawn_left = maxf(0.0, client_respawn_left - dt)
		hud.show_respawn(client_respawn_left)
	_client_wire_weapon()
	if player and player.camera:
		client_aim_from = player.camera.global_position
		client_aim_dir = -player.camera.global_transform.basis.z
	_client_send_input()

func _on_net_event(ev: Dictionary) -> void:
	if net_mode != "client":
		return
	match str(ev.get("kind", "")):
		"died":
			var vteam := int(ev.get("vteam", 0))
			var kteam := int(ev.get("kteam", -1))
			hud.killfeed(str(ev.get("victim", "?")), str(ev.get("killer", "?")),
				bool(ev.get("headshot", false)), vteam, kteam if kteam >= 0 else vteam)
			if int(ev.get("shooter", -99)) == my_net_id:
				hud.hitmarker(bool(ev.get("headshot", false)), bool(ev.get("killed", false)))
				client_kills += 1
			if int(ev.get("victim_id", -999)) == my_net_id:
				client_deaths += 1
			FX.death_poof(fx, RemotePuppet._v3(ev.get("pos", Vector3.ZERO)),
				ArenaConfig.TEAM_COLORS[vteam % 2])
		"respawn":
			if int(ev.get("pid", -999)) == my_net_id and player:
				player.respawn_at(RemotePuppet._v3(ev.get("pos", Vector3.ZERO)),
					float(ev.get("yaw", 0.0)))
				client_respawn_left = 0.0
				hud.show_respawn(0.0)
		"pickup":
			_apply_pickup_grant(ev)
		"left":
			hud.killfeed(str(ev.get("name", "player")) + " left", "", false, 0, 0)
		"match_over":
			_client_match_over(ev)

func _apply_pickup_grant(ev: Dictionary) -> void:
	var idx := int(ev.get("box", -1))
	if idx >= 0 and idx < net_boxes.size():
		(net_boxes[idx] as PickupItem).take_local()
	if int(ev.get("pid", -999)) == my_net_id and player:
		player.pickup_ammo(str(ev.get("key", "")), int(ev.get("amt", 0)))

func _on_net_shot(shot: Dictionary) -> void:
	if net_mode != "client":
		return
	if int(shot.get("shooter", -999)) == my_net_id:
		return # own shots already rendered locally
	for pair in shot.get("shots", []):
		var a := RemotePuppet._v3(pair[0])
		var b := RemotePuppet._v3(pair[1])
		FX.tracer(fx, a, b)
		FX.impact(fx, b, Vector3.UP, false, "rock" if b.y > 0.5 else "dust")

func _on_net_lobby(room: Dictionary) -> void:
	if am_host:
		return
	net_room = room
	if phase == Phase.MENU and my_pid != "":
		menus.show_lobby(room, my_pid, false)

func _on_net_welcome(info: Dictionary) -> void:
	if not bool(info.get("ok", false)):
		menus.join_error_message(str(info.get("error", "Join failed")))
		if net:
			net.close()
		return
	my_net_id = int(info.get("cid", 0))
	my_pid = "netguest"
	net_room = {"players": info.get("players", [])}
	# the guest must know which room it is in, so its own telemetry is
	# attributed to the right room/session on the monitor
	my_room_code = pending_code
	menus.show_lobby({"code": pending_code, "players": info.get("players", []),
		"max_players": 8, "mode": str(info.get("mode", "NORMAL"))}, my_pid, false)

func _on_net_starting(info: Dictionary) -> void:
	start_net_client(info)

func _client_match_over(ev: Dictionary) -> void:
	phase = Phase.GAMEOVER
	if player:
		player.set_physics_process(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	touch_ui.set_match_visible(false)
	_save_match()
	menus.show_results(int(ev.get("winner", -1)), int(ev.get("s0", 0)), int(ev.get("s1", 0)),
		ev.get("rows", []))

# ---------------- client join flow ----------------
func _on_join_manual() -> void:
	var code := menus.join_edit.text.strip_edges()
	var addr := menus.join_ip_edit.text.strip_edges()
	if not RoomManager.is_valid_code_format(code):
		menus.join_error_message("Enter a valid 6-digit room code")
		return
	if addr == "":
		menus.join_error_message("Enter the server address (host:port)")
		return
	# Accept "host:port", "ws://host:port", or "wss://host/path".
	var hostport := addr
	for sch in ["wss://", "ws://", "https://", "http://"]:
		if hostport.begins_with(sch):
			hostport = hostport.substr(sch.length())
			break
	hostport = hostport.get_slice("/", 0)
	var ip := hostport
	var port := GAME_PORT
	if hostport.count(":") == 1:
		port = int(hostport.get_slice(":", 1))
		ip = hostport.get_slice(":", 0)
	if ip == "":
		menus.join_error_message("Enter a valid server address")
		return
	_start_net_join(ip, port, code)

func _start_net_join(ip: String, port: int, code: String) -> void:
	_ensure_net()
	pending_code = code
	# The monitor runs on the same PC as the room host, so a client that
	# reached 192.168.x.y for the game must report to 192.168.x.y too. Without
	# this a phone would post its telemetry to its own loopback and the
	# dashboard would never record a second device.
	monitor.resolve_base_url("", ip)
	if not net.join(ip, port):
		menus.join_error_message("Could not connect to %s:%d" % [ip, port])
		return
	menus.join_error_message("Connecting to %s:%d..." % [ip, port])
	# hello is sent once the link is up (see _physics_process watcher)
	_pending_hello = true

var _pending_hello := false

