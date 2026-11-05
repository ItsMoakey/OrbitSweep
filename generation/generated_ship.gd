extends Node3D
## Playable level wrapper; Ship finishes its initial generation before this node is ready.

@onready var player: CharacterBody3D = $Player
@onready var ship: ShipGenerator = $Ship
@onready var room_visibility: RoomVisibility = $RoomVisibility
@onready var ship_map: ShipMap = $HUD/ShipMap
@onready var status: Label = $HUD/Status


func _ready() -> void:
	ship_map.setup(ship, player, room_visibility)
	ship.generation_completed.connect(_on_generation_completed)
	ship.generation_failed.connect(_on_generation_failed)
	# Child _ready signals have already fired by the time the level becomes ready.
	if ship.rooms.is_empty():
		_on_generation_failed(ship.last_error)
	else:
		_on_generation_completed()


func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_F5:
			get_viewport().set_input_as_handled()
			ship.generate(0)
		KEY_F6:
			get_viewport().set_input_as_handled()
			ship.generate(ship.used_seed)
		KEY_K:
			get_viewport().set_input_as_handled()
			room_visibility.enabled = not room_visibility.enabled
			status.text = _layout_status()
		KEY_TAB:
			get_viewport().set_input_as_handled()
			ship_map.toggle()
		KEY_PAGEUP:
			if ship_map.visible:
				get_viewport().set_input_as_handled()
				ship_map.change_deck(1)
		KEY_PAGEDOWN:
			if ship_map.visible:
				get_viewport().set_input_as_handled()
				ship_map.change_deck(-1)
		KEY_PLUS, KEY_EQUAL, KEY_KP_ADD:
			if ship_map.visible:
				get_viewport().set_input_as_handled()
				ship_map.change_zoom(1)
		KEY_MINUS, KEY_KP_SUBTRACT:
			if ship_map.visible:
				get_viewport().set_input_as_handled()
				ship_map.change_zoom(-1)
		KEY_HOME:
			if ship_map.visible:
				get_viewport().set_input_as_handled()
				ship_map.center_player()
		KEY_END:
			if ship_map.visible:
				get_viewport().set_input_as_handled()
				ship_map.fit_explored()


func _on_generation_completed() -> void:
	# The airlock is always rooms[0]; its origin is clear of the floor and shell.
	player.global_transform = ship.rooms[0].global_transform
	player.velocity = Vector3.ZERO
	for socket in ship.rooms[0].get_doors():
		if socket.peer:
			player.look_at(socket.global_position, Vector3.UP)
			break
	player.get_node("HeadOriginalPos/Head/CameraSmooth/Camera3D").rotation = Vector3.ZERO
	player.reset_physics_interpolation()
	room_visibility.reset()
	ship_map.refresh()
	status.modulate = Color.WHITE
	status.text = _layout_status()


func _on_generation_failed(reason: String) -> void:
	status.modulate = Color(1.0, 0.55, 0.45)
	status.text = "%s\nGeneration failed: %s" % [_layout_status(), reason]


func _layout_status() -> String:
	var reactor_status := "unavailable"
	var bridge_status := "unavailable"
	for index in range(ship.rooms.size()):
		var kind := ship.rooms[index].room_kind
		if kind not in [&"bridge", &"reactor"] or ship.graph.get_id_path(0, index).is_empty():
			continue
		if kind == &"bridge":
			bridge_status = "reachable"
		else:
			reactor_status = "reachable"
	return "Seed: %d  |  Rooms: %d\nF5: new layout  |  F6: repeat seed  |  K: culling %s\nReactor: %s  |  Bridge: %s" % [ship.used_seed, ship.rooms.size(), "on" if room_visibility.enabled else "off", reactor_status, bridge_status]
