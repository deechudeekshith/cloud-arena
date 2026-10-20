# Regen + friendly-fire verification, headless.
# Run: godot --headless --path <project> --script res://tests/FFRegenSim.gd
extends SceneTree

var frames := 0
var main: Node = null
var stage := 0
var stage_t0 := 0
var results: Array = []
var hp_after_hit := 0.0

func _now() -> int:
	return Time.get_ticks_msec()

func _initialize() -> void:
	var ps: PackedScene = load("res://scenes/main/Main.tscn")
	main = ps.instantiate()
	root.add_child(main)

func _process(_dt: float) -> bool:
	frames += 1
	if frames == 5:
		main.start_match()
		stage_t0 = _now()
		stage = 1
		return false
	if frames < 6 or main.phase != 2:
		return false
	var p = main.player
	match stage:
		1: # friendly fire: ally must take nothing, enemy must take damage
			var ally: Node = null
			var foe: Node = null
			for c in main.combatants:
				if c == p:
					continue
				if int(c.get("team_id")) == 0 and ally == null:
					ally = c
				if int(c.get("team_id")) == 1 and foe == null:
					foe = c
			var ahp: float = ally.get("health").hp
			var fhp: float = foe.get("health").hp
			main.deal_damage(ally, 40.0, 0, false, ally.global_position, Vector3.UP)
			main.deal_damage(foe, 40.0, 0, false, foe.global_position, Vector3.UP)
			_check("friendly fire blocked", absf(ally.get("health").hp - ahp) < 0.01,
				"ally hp=%0.1f" % ally.get("health").hp)
			_check("enemy damage applies", foe.get("health").hp < fhp - 30.0,
				"foe hp=%0.1f" % foe.get("health").hp)
			p.apply_hit(50.0, 99, false, p.global_position, Vector3.UP)
			hp_after_hit = p.health.hp
			stage_t0 = _now()
			stage = 2
		2: # no instant regen: hp flat for the first ~2s
			if float(_now() - stage_t0) / 1000.0 > 2.0:
				_check("no instant regen", p.health.hp <= hp_after_hit + 0.5,
					"hp=%0.1f" % p.health.hp)
				hp_after_hit = p.health.hp
				stage = 3
		3: # regen kicks in after the 5s delay
			if float(_now() - stage_t0) / 1000.0 > 7.0:
				_check("delayed regen heals", p.health.hp > hp_after_hit + 2.0,
					"hp=%0.1f was %0.1f" % [p.health.hp, hp_after_hit])
				_report()
				return true
	return false

func _check(name: String, ok: bool, detail: String) -> void:
	results.append(ok)
	print("FFREGEN: [%s] %s (%s)" % ["PASS" if ok else "FAIL", name, detail])

func _report() -> void:
	var fails := 0
	for r in results:
		if not r:
			fails += 1
	print("FFREGEN: DONE %d/%d passed" % [results.size() - fails, results.size()])
