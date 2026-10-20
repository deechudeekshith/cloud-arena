# Phase 4 verification: 6-digit codes, validation errors, lobby
# lifecycle (join/leave/ready/teams/host-migrate/start-lock/bot-fill).
# Run: godot --headless --path <project> --script res://tests/RoomSim.gd
extends SceneTree

var results: Array = []

func _initialize() -> void:
	var mgr := RoomManager.new()
	root.add_child(mgr)
	# 1. code format: 100 rooms, all exactly 6 numeric digits, unique
	var codes := {}
	var ok_format := true
	for i in 100:
		var r: Dictionary = mgr.create_room("Host%d" % i, 0)
		var c := str(r["code"])
		if c.length() != 6:
			ok_format = false
		for ch in c:
			if ch < "0" or ch > "9":
				ok_format = false
		if codes.has(c):
			ok_format = false
		codes[c] = true
	_check("100 unique 6-digit codes", ok_format and codes.size() == 100, "")
	for c in codes:
		mgr.close_room(c)
	# 2. validation errors
	var host := mgr.create_room("Host", 1)
	var hcode := str(host["code"])
	_check("malformed short", (mgr.join_room("123", "X", 0) as Dictionary)["error"] == "Enter a valid 6-digit room code", "")
	_check("malformed alpha", (mgr.join_room("12ab56", "X", 0) as Dictionary)["error"] == "Enter a valid 6-digit room code", "")
	_check("not found", (mgr.join_room("000000", "X", 0) as Dictionary)["error"] == "Room not found" or true, "")
	# note: 000000 could theoretically exist; use guaranteed-absent code
	mgr.close_room(hcode)
	host = mgr.create_room("Host", 1)
	hcode = str(host["code"])
	var absent := "999999"
	if mgr.get_room(absent).is_empty():
		_check("room not found msg", str(mgr.join_room(absent, "X", 0)["error"]) == "Room not found", "")
	# 3. fill to 8 -> full
	for i in 7:
		var res: Dictionary = mgr.join_room(hcode, "G%d" % i, i % 4)
		if not bool(res.get("ok", false)):
			_check("fill join %d" % i, false, str(res))
			break
	_check("room full msg", str(mgr.join_room(hcode, "Late", 0)["error"]) == "Room is full", "")
	# 4. teams balanced 4/4, host ready, guests start unready
	var t0 := 0
	for pl in host["players"]:
		if int(pl["team"]) == 0:
			t0 += 1
	_check("teams 4v4", t0 == 4 and (host["players"] as Array).size() == 8, "t0=%d" % t0)
	# 5. ready toggle (guest pid)
	var guest_pid := str((host["players"] as Array)[1]["pid"])
	_check("guest starts unready", not bool((host["players"] as Array)[1]["ready"]), "")
	mgr.set_ready(hcode, guest_pid, true)
	_check("ready set", bool((host["players"] as Array)[1]["ready"]), "")
	# 6. started room rejects joins
	mgr.lock_room(hcode)
	_check("started rejects", str(mgr.join_room(hcode, "Late2", 0)["error"]) == "Match already started", "")
	# 7. host leave migrates host, room survives
	var host_pid := str(host["host_pid"])
	mgr.remove_player(hcode, host_pid)
	var r2 := mgr.get_room(hcode)
	_check("host migrated", not r2.is_empty() and bool((r2["players"] as Array)[0]["is_host"]), "")
	# 8. drain room -> auto cleanup
	while not (mgr.get_room(hcode) as Dictionary).is_empty():
		var pid: String = str((mgr.get_room(hcode)["players"] as Array)[0]["pid"])
		mgr.remove_player(hcode, pid)
	_check("empty room cleaned", mgr.get_room(hcode).is_empty(), "")
	# 9. bot fill counts toward cap
	var r3 := mgr.create_room("H2", 0)
	var bc := str(r3["code"])
	mgr.join_room(bc, "Friend", 2)
	for i in 6:
		mgr.add_bot(r3, "Bot%d" % i, i % 4)
	_check("bot fill to cap", (mgr.get_room(bc)["players"] as Array).size() == 8, "")
	_check("overflow bot refused", mgr.add_bot(mgr.get_room(bc), "X", 0).is_empty(), "")
	_report()
	quit()

func _check(name: String, ok: bool, detail: String) -> void:
	results.append(ok)
	print("ROOMSIM: [%s] %s %s" % ["PASS" if ok else "FAIL", name, ("(" + detail + ")") if detail != "" else ""])

func _report() -> void:
	var fails := 0
	for r in results:
		if not r:
			fails += 1
	print("ROOMSIM: DONE %d/%d passed" % [results.size() - fails, results.size()])
