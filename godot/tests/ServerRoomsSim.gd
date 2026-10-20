# Server monitor verification: rooms default to OPTIMIZED, and the PC's
# SERVER ROOMS snapshot lists every room with full player details.
# Run: godot --headless --path <project> --script res://tests/ServerRoomsSim.gd
extends SceneTree

var frames := 0
var main: Node = null
var results: Array = []

func _initialize() -> void:
	var ps: PackedScene = load("res://scenes/main/Main.tscn")
	main = ps.instantiate()
	root.add_child(main)

func _process(_dt: float) -> bool:
	frames += 1
	if frames == 5:
		main._on_create_room()
		var code: String = main.my_room_code
		var room: Dictionary = main.room_mgr.get_room(code)
		_check("room created", not room.is_empty(), code)
		_check("optimized by default", str(room.get("mode", "?")) == "OPTIMIZED",
			str(room.get("mode", "?")))
		_check("lobby opt shows optimized", main.menus.room_mode_opt.selected == 1,
			"selected=%d" % main.menus.room_mode_opt.selected)
		main.room_mgr.join_room(code, "Guest", 1)
		var snap: Array = main._server_rooms_snapshot()
		_check("snapshot lists the room", snap.size() == 1,
			"n=%d" % snap.size())
		var d: Dictionary = snap[0]
		_check("snapshot marks mine", bool(d.get("is_mine", false)), code)
		_check("snapshot has both players", (d.get("players", []) as Array).size() == 2,
			"n=%d" % (d.get("players", []) as Array).size())
		_check("snapshot carries seed+state",
			str(d.get("map_seed", "")) != "" and str(d.get("state", "")) == "LOBBY",
			"%s/%s" % [str(d.get("state", "?")), str(d.get("map_seed", "?"))])
		main.menus.show_screen("ROOMS")
		main.menus.refresh_rooms()
		_check("rooms screen builds rows", main.menus.rooms_list.get_child_count() > 3,
			"rows=%d" % main.menus.rooms_list.get_child_count())
		_check("lobby codec line mentions optimized",
			"OPTIMIZED" in main._lobby_netstats(), main._lobby_netstats())
		_report()
		return true
	return false

func _check(name: String, ok: bool, detail: String) -> void:
	results.append(ok)
	print("SRVROOMS: [%s] %s (%s)" % ["PASS" if ok else "FAIL", name, detail])

func _report() -> void:
	var fails := 0
	for r in results:
		if not r:
			fails += 1
	print("SRVROOMS: DONE %d/%d passed" % [results.size() - fails, results.size()])
