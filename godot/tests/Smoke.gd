# Headless smoke test: boots Main, starts a match, simulates 30s of bot
# combat + respawns, then prints a NetworkState snapshot summary.
# Run: godot --headless --path <project> --script res://tests/Smoke.gd
extends SceneTree

var frames := 0
var main: Node = null
const MAX_FRAMES := 6000 # long sim: kills, respawns, match end

func _initialize() -> void:
	var ps: PackedScene = load("res://scenes/main/Main.tscn")
	main = ps.instantiate()
	root.add_child(main)

func _process(_dt: float) -> bool:
	frames += 1
	if frames == 5:
		main.start_match()
		print("SMOKE: match started, combatants=", main.combatants.size())
	if frames < 6:
		return false
	# wiggle the human forward so movement code paths run
	if main and main.player and not bool(main.player.get("dead")):
		Input.action_press("move_forward")
		if frames % 120 == 0:
			Input.action_press("fire")
		if frames % 120 == 30:
			Input.action_release("fire")
	if frames >= MAX_FRAMES:
		var snap: Dictionary = main.get_match_snapshot()
		print("SMOKE: frames=", frames, " phase=", main.phase,
			" scores=", main.team_scores, " time_left=", snap_time(snap),
			" players=", (snap.get("players", []) as Array).size(),
			" bytes=", NetworkState.measure(snap).get("bytes", -1))
		for c in main.combatants:
			if is_instance_valid(c):
				print("SMOKE: id=", c.player_id, " hp=", c.health.hp,
					" dead=", c.get("dead"), " pos=", c.position)
		print("SMOKE: DONE")
		return true
	return false

func snap_time(s: Dictionary) -> float:
	return float(s.get("time_left", -1.0))
