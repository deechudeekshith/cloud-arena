# Minimal WebSocketMultiplayerPeer loopback probe.
# server: --role=server
# client: --role=client
extends SceneTree

var role := "server"
var t0 := 0
var frames := 0
var ws: WebSocketMultiplayerPeer

func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			role = a.get_slice("=", 1)
	t0 = Time.get_ticks_msec()

func _process(_dt: float) -> bool:
	frames += 1
	if frames == 3:
		ws = WebSocketMultiplayerPeer.new()
		if role == "server":
			var err := ws.create_server(8899)
			print("WSPROBE server create err=", err)
			root.multiplayer.multiplayer_peer = ws
			root.multiplayer.peer_connected.connect(func(id: int) -> void:
				print("WSPROBE server peer_connected id=", id))
		else:
			var err := ws.create_client("ws://127.0.0.1:8899")
			print("WSPROBE client create err=", err)
			root.multiplayer.multiplayer_peer = ws
			root.multiplayer.connected_to_server.connect(func() -> void:
				print("WSPROBE client connected_to_server uid=", root.multiplayer.get_unique_id()))
			root.multiplayer.connection_failed.connect(func() -> void:
				print("WSPROBE client connection_failed"))
	var el := float(Time.get_ticks_msec() - t0) / 1000.0
	if frames > 3 and frames % 30 == 0:
		var mp := root.multiplayer.multiplayer_peer
		if mp:
			print("WSPROBE ", role, " t=%0.1f" % el, " status=", mp.get_connection_status(),
				" uid=", root.multiplayer.get_unique_id(),
				" peers=", root.multiplayer.get_peers())
	if el > 6.0:
		print("WSPROBE ", role, " DONE")
		quit()
		return true
	return false
