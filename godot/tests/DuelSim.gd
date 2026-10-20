# Bot lethality/fairness probe: one enemy bot vs a stationary player dummy
# at 12m, open ground. Expects: bot opens fire after a fair reaction
# (no instant melt), lands real damage, and CAN kill within 40s.
# Run: godot --headless --path <project> --script res://tests/DuelSim.gd
extends SceneTree

var frames := 0
var main: Node = null
var stage := 0
var stage_frame := 0
var stage_t0 := 0
var results: Array = []
var hp0 := 100.0
var min_hp := 100.0
var first_dmg_t := -1.0
var kill_t := -1.0
var calmed := false

func _initialize() -> void:
	var ps: PackedScene = load("res://scenes/main/Main.tscn")
	main = ps.instantiate()
	root.add_child(main)

func _sec() -> float:
	return float(Time.get_ticks_msec() - stage_t0) / 1000.0

func _process(_dt: float) -> bool:
	frames += 1
	if frames == 5:
		main.start_match()
		var p = main.player
		p.health.regen_rate = 0.0 # measure raw bot damage, no regen
		p.global_position = Vector3(0, 0.3, 20)
		p.velocity = Vector3.ZERO
		p.rotation.y = 0.0
		p.set("yaw", 0.0)
		return false
	if frames < 6 or main.phase != 2:
		return false
	# freeze all bots only once PLAYING actually starts (match start
	# re-enables physics on every combatant when the countdown ends)
	if not calmed:
		calmed = true
		for c in main.combatants:
			if c != main.player and c is BotController:
				(c as BotController).set_physics_process(false)
		hp0 = main.player.health.hp
		stage_t0 = Time.get_ticks_msec()
		stage = 1
		stage_frame = frames
		print("DUELSIM: stage 1 no-enemy calm (5s, expect no damage)")
		return false
	var p = main.player
	match stage:
		1: # no live enemy yet: hp must stay flat
			if _sec() > 5.0:
				_check("no phantom damage", p.health.hp >= hp0 - 0.5,
					"hp=%0.1f" % p.health.hp)
				# release the nearest enemy bot, 12m south of the player
				var foe: BotController = null
				var best := 1e9
				for c in main.combatants:
					if c is BotController and int(c.get("team_id")) == 1:
						var d: float = (c as Node3D).global_position.distance_to(p.global_position)
						if d < best:
							best = d
							foe = c
				foe.global_position = Vector3(0, 0.3, 32)
				foe.set("skill", 0.8)
				foe.set_physics_process(true)
				hp0 = p.health.hp
				stage_t0 = Time.get_ticks_msec()
				stage = 2
				print("DUELSIM: stage 2 live enemy @12m (skill 0.8)")
		2: # fair fight: first damage after reaction, kill possible < 40s
			min_hp = minf(min_hp, p.health.hp)
			if first_dmg_t < 0.0 and p.health.hp < hp0 - 1.0:
				first_dmg_t = _sec()
				_check("reaction not instant", first_dmg_t > 0.25,
					"t=%0.2fs" % first_dmg_t)
			if kill_t < 0.0 and bool(p.get("dead")):
				kill_t = _sec()
			if _sec() > 40.0:
				_check("bot lands damage", min_hp < hp0 - 20.0,
					"min_hp=%0.1f" % min_hp)
				_check("bot can kill", kill_t > 0.0,
					"kill_t=%0.1fs" % kill_t)
				_check("no instant melt", kill_t < 0.0 or kill_t > 1.5,
					"kill_t=%0.1fs" % kill_t)
				_report()
				return true
	return false

func _check(name: String, ok: bool, detail: String) -> void:
	results.append(ok)
	print("DUELSIM: [%s] %s (%s)" % ["PASS" if ok else "FAIL", name, detail])

func _report() -> void:
	var fails := 0
	for r in results:
		if not r:
			fails += 1
	print("DUELSIM: DONE %d/%d passed" % [results.size() - fails, results.size()])
