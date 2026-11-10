extends Node
class_name HealthServer

## Simple HTTP health check server for Render.com
## Responds to /health requests with 200 OK
## This keeps Render happy and prevents unnecessary service restarts

var server: TCPServer
var clients: Array[StreamPeerTCP] = []
var port: int = 10000
var running := false

func _ready() -> void:
	# Read port from environment if available (Render sets this)
	var env_port = OS.get_environment("PORT")
	if env_port != "":
		port = int(env_port)
	
	print("[HealthServer] Starting health check server on port %d" % port)

func start(listen_port: int = -1) -> bool:
	if listen_port > 0:
		port = listen_port
	
	server = TCPServer.new()
	var err = server.listen(port, "0.0.0.0")
	if err != OK:
		push_error("[HealthServer] Failed to start on port %d: %d" % [port, err])
		return false
	
	running = true
	print("[HealthServer] Listening on 0.0.0.0:%d" % port)
	return true

func stop() -> void:
	running = false
	for client in clients:
		client.disconnect_from_host()
	clients.clear()
	if server:
		server.stop()
	print("[HealthServer] Stopped")

func _process(_delta: float) -> void:
	if not running or not server:
		return
	
	# Accept new connections
	if server.is_connection_available():
		var client = server.take_connection()
		if client:
			clients.append(client)
	
	# Process existing clients
	var to_remove: Array[StreamPeerTCP] = []
	
	for client in clients:
		match client.get_status():
			StreamPeerTCP.STATUS_NONE, StreamPeerTCP.STATUS_ERROR:
				to_remove.append(client)
				continue
			StreamPeerTCP.STATUS_CONNECTED:
				# Read HTTP request
				var available = client.get_available_bytes()
				if available > 0:
					var request = client.get_string(available)
					_handle_request(client, request)
					to_remove.append(client)  # Close after response (HTTP/1.0 style)
	
	# Remove disconnected clients
	for client in to_remove:
		clients.erase(client)

func _handle_request(client: StreamPeerTCP, request: String) -> void:
	# Parse HTTP method and path
	var lines = request.split("\r\n", false)
	if lines.size() == 0:
		return
	
	var first_line = lines[0].split(" ")
	if first_line.size() < 2:
		return
	
	var method = first_line[0]
	var path = first_line[1]
	
	# Handle /health endpoint
	if path == "/health" or path.begins_with("/health"):
		_send_response(client, 200, "OK", "text/plain", "healthy")
	else:
		_send_response(client, 404, "Not Found", "text/plain", "Endpoint not found. Use /health")

func _send_response(client: StreamPeerTCP, status: int, status_text: String, 
					content_type: String, body: String) -> void:
	var response = ""
	response += "HTTP/1.1 %d %s\r\n" % [status, status_text]
	response += "Content-Type: %s\r\n" % content_type
	response += "Content-Length: %d\r\n" % body.length()
	response += "Connection: close\r\n"
	response += "\r\n"
	response += body
	
	client.put_data(response.to_utf8_buffer())
