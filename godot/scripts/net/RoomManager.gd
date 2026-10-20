class_name RoomManager
extends Node

## Local room registry + lifecycle. Rooms live in this process (hosts).
## 6-digit numeric codes, max 8 players, host/ready/teams/lock.
## LAN/internet joining is resolved by RoomDiscovery (code -> address);
## this class never fakes remote connectivity.

signal lobby_changed(code: String)

const MAX_PLAYERS := 8
const CODE_LEN := 6

var rooms := {} # code(String) -> room Dictionary
var _pid_seq := 0

static func is_valid_code_format(code: String) -> bool:
	if code.length() != CODE_LEN:
		return false
	for i in CODE_LEN:
		var ch := code[i]
		if ch < "0" or ch > "9":
			return false
	return true

func _new_code() -> String:
	for attempt in 200:
		var c := ""
		for i in CODE_LEN:
			c += str(randi_range(0, 9) if i > 0 else randi_range(1, 9))
		if not rooms.has(c):
			return c
	return ""

func _new_pid() -> String:
	_pid_seq += 1
	return "p%d_%d" % [Time.get_ticks_msec() % 100000, _pid_seq]

func create_room(host_name: String, avatar_id: int) -> Dictionary:
	var code := _new_code()
	if code == "":
		return {}
	var room := {
		"code": code,
		"room_id": "room_%s_%d" % [code, Time.get_ticks_msec() % 1000000],
		"host_pid": "",
		"players": [],
		"max_players": MAX_PLAYERS,
		"mode": "OPTIMIZED", # optimization applied by default (delta/dedup/compress codec)
		"bot_count": 0, # extra bots beyond auto-fill (host option)
		"state": "LOBBY", # LOBBY -> LOCKED -> PLAYING -> DONE
		"map_seed": randi(),
		"created_at": Time.get_datetime_string_from_system(),
	}
	rooms[code] = room
	var host := _add_player(room, host_name, avatar_id, true, false)
	room["host_pid"] = host["pid"]
	lobby_changed.emit(code)
	return room

func get_room(code: String) -> Dictionary:
	return rooms.get(code, {})

func _add_player(room: Dictionary, pname: String, avatar_id: int, is_host: bool, is_bot: bool) -> Dictionary:
	var players: Array = room["players"]
	# balance teams: join the smaller team (0 on ties)
	var t0 := 0
	for pl in players:
		if int(pl["team"]) == 0:
			t0 += 1
	var entry := {
		"pid": _new_pid(), "name": pname, "avatar_id": avatar_id,
		"team": 0 if t0 * 2 <= players.size() else 1,
		"ready": is_host, "is_host": is_host, "is_bot": is_bot,
		"peer_id": 0, "conn": "local" if not is_bot else "bot",
	}
	players.append(entry)
	return entry

## Returns {ok: bool, error: String, player: Dictionary}
func join_room(code: String, pname: String, avatar_id: int) -> Dictionary:
	if not is_valid_code_format(code):
		return {"ok": false, "error": "Enter a valid 6-digit room code"}
	if not rooms.has(code):
		return {"ok": false, "error": "Room not found"}
	var room: Dictionary = rooms[code]
	if str(room["state"]) != "LOBBY":
		return {"ok": false, "error": "Match already started"}
	if (room["players"] as Array).size() >= int(room["max_players"]):
		return {"ok": false, "error": "Room is full"}
	var entry := _add_player(room, pname, avatar_id, false, false)
	lobby_changed.emit(code)
	return {"ok": true, "player": entry, "room": room}

func add_bot(room: Dictionary, bot_name: String, avatar_id: int) -> Dictionary:
	if (room["players"] as Array).size() >= int(room["max_players"]):
		return {}
	var entry := _add_player(room, bot_name, avatar_id, false, true)
	entry["ready"] = true
	lobby_changed.emit(str(room["code"]))
	return entry

func set_ready(code: String, pid: String, ready: bool) -> bool:
	var room := get_room(code)
	if room.is_empty():
		return false
	for pl in room["players"]:
		if str(pl["pid"]) == pid and not bool(pl["is_host"]):
			pl["ready"] = ready
			lobby_changed.emit(code)
			return true
	return false

func set_mode(code: String, mode: String) -> bool:
	var room := get_room(code)
	if room.is_empty() or str(room["state"]) != "LOBBY":
		return false
	if mode != "NORMAL" and mode != "OPTIMIZED":
		return false
	room["mode"] = mode
	lobby_changed.emit(code)
	return true

func remove_player(code: String, pid: String) -> bool:
	var room := get_room(code)
	if room.is_empty():
		return false
	var players: Array = room["players"]
	for i in players.size():
		if str(players[i]["pid"]) == pid:
			var was_host := bool(players[i]["is_host"])
			players.remove_at(i)
			if players.is_empty():
				rooms.erase(code) # last one out closes the room
				return true
			if was_host:
				players[0]["is_host"] = true
				players[0]["ready"] = true
				room["host_pid"] = players[0]["pid"]
			lobby_changed.emit(code)
			return true
	return false

func lock_room(code: String) -> bool:
	var room := get_room(code)
	if room.is_empty() or str(room["state"]) != "LOBBY":
		return false
	room["state"] = "LOCKED"
	lobby_changed.emit(code)
	return true

func set_state(code: String, state: String) -> bool:
	var room := get_room(code)
	if room.is_empty():
		return false
	room["state"] = state
	lobby_changed.emit(code)
	return true

func close_room(code: String) -> void:
	rooms.erase(code)

func human_count(room: Dictionary) -> int:
	var n := 0
	for pl in room["players"]:
		if not bool(pl["is_bot"]):
			n += 1
	return n

## Look up a player's display name (empty string if gone).
func human_name(code: String, pid: String) -> String:
	var room := get_room(code)
	if room.is_empty():
		return ""
	for pl in room["players"]:
		if str(pl["pid"]) == pid:
			return str(pl.get("name", "?"))
	return ""

## Device identity recorded when the player joined ("" if unknown).
func device_of(code: String, pid: String) -> String:
	var room := get_room(code)
	if room.is_empty():
		return ""
	for pl in room["players"]:
		if str(pl["pid"]) == pid:
			return str(pl.get("device_id", ""))
	return ""

func all_ready(room: Dictionary) -> bool:
	for pl in room["players"]:
		if not bool(pl["ready"]):
			return false
	return true
