class_name RoomRegistry
extends Node

## Cloud-based room registry for internet multiplayer
## Registers rooms on a central server so players across different networks can find each other

signal room_registered(code: String, success: bool)
signal room_lookup_complete(code: String, found: bool, host_data: Dictionary)
signal registry_error(error: String)

var registry_url := ""
var http_request: HTTPRequest
var pending_requests := {}  # request_id -> {type, code, callback}
var last_heartbeat := 0.0
var heartbeat_interval := 30.0  # Send heartbeat every 30 seconds
var my_room_code := ""

func _ready() -> void:
	# Create HTTPRequest node
	http_request = HTTPRequest.new()
	add_child(http_request)
	http_request.request_completed.connect(_on_http_request_completed)

func set_registry_url(url: String) -> void:
	"""Set the room registry server URL"""
	registry_url = url
	if not registry_url.ends_with("/"):
		registry_url += "/"
	print("[RoomRegistry] Registry URL: %s" % registry_url)

func register_room(code: String, host_ip: String, port: int, host_name: String, 
                   max_players: int = 8, current_players: int = 1) -> void:
	"""Register a new room on the registry server"""
	if registry_url == "":
		push_error("[RoomRegistry] No registry URL set!")
		registry_error.emit("No registry URL configured")
		return
	
	my_room_code = code
	
	var data := {
		"code": code,
		"host_ip": host_ip,
		"port": port,
		"host_name": host_name,
		"max_players": max_players,
		"current_players": current_players
	}
	
	var url := registry_url + "registry/rooms/register"
	var body := JSON.stringify(data)
	var headers := ["Content-Type: application/json"]
	
	print("[RoomRegistry] Registering room %s at %s:%d" % [code, host_ip, port])
	
	var err := http_request.request(url, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		push_error("[RoomRegistry] Failed to send registration request: %d" % err)
		registry_error.emit("Failed to send registration request")
		room_registered.emit(code, false)
	else:
		pending_requests[http_request.get_http_client_status()] = {
			"type": "register",
			"code": code
		}

func lookup_room(code: String) -> void:
	"""Look up a room by code"""
	if registry_url == "":
		push_error("[RoomRegistry] No registry URL set!")
		registry_error.emit("No registry URL configured")
		return
	
	var url := registry_url + "registry/rooms/" + code
	var headers := ["Content-Type: application/json"]
	
	print("[RoomRegistry] Looking up room %s" % code)
	
	var err := http_request.request(url, headers, HTTPClient.METHOD_GET)
	if err != OK:
		push_error("[RoomRegistry] Failed to send lookup request: %d" % err)
		registry_error.emit("Failed to send lookup request")
		room_lookup_complete.emit(code, false, {})
	else:
		pending_requests[http_request.get_http_client_status()] = {
			"type": "lookup",
			"code": code
		}

func send_heartbeat(current_players: int = 1) -> void:
	"""Send heartbeat to keep room alive"""
	if my_room_code == "" or registry_url == "":
		return
	
	var data := {
		"code": my_room_code,
		"current_players": current_players
	}
	
	var url := registry_url + "registry/rooms/heartbeat"
	var body := JSON.stringify(data)
	var headers := ["Content-Type: application/json"]
	
	var err := http_request.request(url, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		print("[RoomRegistry] Heartbeat failed: %d" % err)

func unregister_room(code: String) -> void:
	"""Unregister a room from the registry"""
	if registry_url == "":
		return
	
	var data := {"code": code}
	var url := registry_url + "registry/rooms/unregister"
	var body := JSON.stringify(data)
	var headers := ["Content-Type: application/json"]
	
	print("[RoomRegistry] Unregistering room %s" % code)
	
	var err := http_request.request(url, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		print("[RoomRegistry] Failed to unregister: %d" % err)
	
	my_room_code = ""

func _process(delta: float) -> void:
	# Send periodic heartbeat for registered room
	if my_room_code != "":
		last_heartbeat += delta
		if last_heartbeat >= heartbeat_interval:
			last_heartbeat = 0.0
			send_heartbeat()

func _on_http_request_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	"""Handle HTTP request completion"""
	var response_text := body.get_string_from_utf8()
	
	if result != HTTPRequest.RESULT_SUCCESS:
		push_error("[RoomRegistry] HTTP request failed: %d" % result)
		registry_error.emit("HTTP request failed")
		return
	
	var json := JSON.new()
	var parse_err := json.parse(response_text)
	if parse_err != OK:
		push_error("[RoomRegistry] Failed to parse JSON response: %s" % response_text)
		registry_error.emit("Invalid server response")
		return
	
	var data: Dictionary = json.data
	
	# Check which request this was (simplified - using response content)
	if response_code == 200 and data.has("code"):
		var code := str(data.get("code", ""))
		
		if data.has("host") and data.has("port"):
			# This is a lookup response
			print("[RoomRegistry] Room %s found at %s:%d" % [code, data["host"], data["port"]])
			room_lookup_complete.emit(code, true, data)
		elif data.has("message") and "registered" in str(data["message"]).to_lower():
			# This is a registration response
			print("[RoomRegistry] Room %s registered successfully" % code)
			room_registered.emit(code, true)
	
	elif response_code == 404:
		# Room not found
		var code := str(data.get("code", "unknown"))
		print("[RoomRegistry] Room not found: %s" % code)
		room_lookup_complete.emit(code, false, {})
	
	elif not bool(data.get("ok", false)):
		# Error response
		var error := str(data.get("error", "Unknown error"))
		push_error("[RoomRegistry] Server error: %s" % error)
		registry_error.emit(error)
