class_name RoomDiscovery
extends Node

## LAN room discovery over UDP broadcast. Best-effort: fills a
## code -> {ip, port, host, players, max} table the JOIN screen uses.
## No internet lookup is performed or implied; manual LAN address entry
## remains as fallback. All data is real (received packets only).

signal found_updated

const DISCOVER_PORT := 47777
const GAME_VERSION := "1.0"

var found := {} # code -> info dict
var _udp: PacketPeerUDP
var _announce_code := ""
var _announce_info := {}
var _announce_t := 0.0
var _listening := false

func _exit_tree() -> void:
	stop()

func stop() -> void:
	_announce_code = ""
	_listening = false
	if _udp:
		_udp.close()
		_udp = null

func start_hosting(code: String, game_port: int, host_name: String, players: int, max_players: int) -> void:
	stop()
	_announce_code = code
	_announce_info = {"code": code, "port": game_port, "host": host_name,
		"players": players, "max": max_players, "ver": GAME_VERSION}
	_udp = PacketPeerUDP.new()
	_udp.set_broadcast_enabled(true)
	_announce_t = 99.0 # send immediately

func start_listening() -> void:
	stop()
	found.clear()
	_udp = PacketPeerUDP.new()
	var err := _udp.bind(DISCOVER_PORT)
	_listening = err == OK
	if not _listening:
		push_warning("RoomDiscovery: cannot bind UDP %d" % DISCOVER_PORT)
		_udp = null

func _process(dt: float) -> void:
	if _udp == null:
		return
	if _announce_code != "":
		_announce_t += dt
		if _announce_t >= 2.0:
			_announce_t = 0.0
			_udp.set_dest_address("255.255.255.255", DISCOVER_PORT)
			_udp.put_packet(JSON.stringify(
				{"type": "arena_room"}.merged(_announce_info)).to_utf8_buffer())
	if _listening:
		for i in 32: # bounded per frame (lightweight)
			if _udp.get_available_packet_count() <= 0:
				break
			var pkt := _udp.get_packet()
			var from_ip := _udp.get_packet_ip()
			var data = JSON.parse_string(pkt.get_string_from_utf8())
			if data is Dictionary and str(data.get("type", "")) == "arena_room":
				if str(data.get("ver", "")) != GAME_VERSION:
					continue
				var code := str(data.get("code", ""))
				if not RoomManager.is_valid_code_format(code):
					continue
				found[code] = {"ip": from_ip, "port": int(data.get("port", 7777)),
					"host": str(data.get("host", "?")), "players": int(data.get("players", 0)),
					"max": int(data.get("max", 8))}
				found_updated.emit()

func update_presence(players: int) -> void:
	_announce_info["players"] = players
