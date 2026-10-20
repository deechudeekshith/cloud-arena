# Lobby UI proof: create room + guest join, capture ROOM and JOIN cards.
# Run: DISPLAY=:0 godot --path <project> --resolution 1280x720 --script res://tests/ShotRoom.gd
extends SceneTree

var frames := 0
var main: Node = null

func _initialize() -> void:
	var ps: PackedScene = load("res://scenes/main/Main.tscn")
	main = ps.instantiate()
	root.add_child(main)

func _process(_dt: float) -> bool:
	frames += 1
	if frames == 10:
		main._on_create_room()
		main.room_mgr.join_room(main.my_room_code, "Friend", 2)
		main.room_mgr.add_bot(main.room_mgr.get_room(main.my_room_code), "BotAlly (bot)", 1)
		main._on_lobby_changed(main.my_room_code)
	if frames == 40:
		_shot("/tmp/opencode/shots/room_lobby.png")
	if frames == 50:
		main.menus.show_screen("JOIN")
	if frames == 80:
		_shot("/tmp/opencode/shots/room_join.png")
	if frames >= 100:
		print("SHOTROOM: DONE code=", main.my_room_code)
		return true
	return false

func _shot(path: String) -> void:
	await process_frame
	await process_frame
	var img := root.get_texture().get_image()
	print("SHOTROOM: ", path, " err=", img.save_png(path))
