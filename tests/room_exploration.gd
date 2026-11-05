extends SceneTree
## Run: godot --headless --path . --script res://tests/room_exploration.gd
var _failures := 0
func _initialize() -> void:
	call_deferred("_run")
func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures += 1
		push_error(message)
func _enter(room: ShipRoom, player: CharacterBody3D) -> void:
	var socket := room.get_doors()[0]
	player.global_position = socket.global_position + socket.global_basis.z * 1.2
func _toggle_culling_key() -> void:
	var event := InputEventKey.new()
	event.keycode = KEY_K
	event.pressed = true
	Input.parse_input_event(event)
	await process_frame
	await process_frame
func _run() -> void:
	var level: Node3D = load("res://generated_ship.tscn").instantiate()
	var ship: ShipGenerator = level.get_node("Ship")
	ship.room_count = 24
	ship.generation_seed = 42
	root.add_child(level)
	var player: CharacterBody3D = level.get_node("Player")
	player.set_physics_process(false)
	var visibility: Node = level.get_node("RoomVisibility")
	var map: Control = level.get_node("HUD/ShipMap")
	visibility.refresh()
	_check(visibility.current_room == 0, "Spawn must be tracked in the airlock")
	_check(visibility.discovered_rooms.size() == 1 and visibility.discovered_rooms.has(0), "Nearby rendered rooms must not count as explored")
	_check(not map.visible, "Map must not cover gameplay by default")
	map.toggle()
	_check(map.visible and map.discovered_decks.size() == 1, "Initial map must show only the explored spawn deck")
	map.toggle()
	ship.transform = Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(50, 4, -30))
	_enter(ship.rooms[0], player)
	visibility.refresh()
	_check(visibility.current_room == 0, "Moving/rotating the ship broke room tracking")
	var far := -1
	for index in range(ship.rooms.size()):
		if not visibility.active_rooms.has(index):
			far = index
			break
	_check(far >= 0, "Distant rooms must be culled")
	if far >= 0:
		_check(not ship.rooms[far].is_visible_in_tree(), "Culled room geometry remains visible")
		for light in ship.rooms[far].find_children("*", "Light3D", true, false):
			_check(not light.is_visible_in_tree(), "Distant lights remain active")
		# A culled room must still have its real physics floor.
		var socket := ship.rooms[far].get_doors()[0]
		var origin := socket.global_position + socket.global_basis.z * 1.2
		var ray := PhysicsRayQueryParameters3D.create(origin, origin + Vector3.DOWN * 4)
		ray.exclude = [player.get_rid()]
		await physics_frame
		await physics_frame
		var hit := root.world_3d.direct_space_state.intersect_ray(ray)
		_check(not hit.is_empty(), "Culling removed the physical floor")
		_enter(ship.rooms[far], player)
		visibility.refresh()
		_check(visibility.current_room == far, "Crossing rooms did not update player tracking")
		_check(visibility.discovered_rooms.has(far) and visibility.discovered_rooms.has(0), "Exploration memory lost previous rooms")
		_check(ship.rooms[far].is_visible_in_tree(), "Entering a culled room did not restore rendering")
	var stair := -1
	for index in range(ship.rooms.size()):
		if ship.rooms[index].room_kind == &"stairs":
			stair = index
			break
	_check(stair >= 0, "Fixture must exercise a stair transition")
	if stair >= 0:
		for socket in ship.rooms[stair].get_doors():
			player.global_position = socket.global_position + socket.global_basis.z * 1.2
			visibility.refresh()
			_check(visibility.current_room == stair, "Stair elevation lost room tracking")
			map.center_player()
			_check(is_equal_approx(map.player_deck, ship.to_local(socket.global_position).y), "Map did not follow the stair landing's actual deck")
		_check(map.discovered_decks.size() >= 2, "Discovered stair must expose its deck link")
		map.change_deck(-100)
		_check(is_equal_approx(map.selected_deck, map.discovered_decks[0]), "Deck browsing did not select the discovered lower deck")
		map.change_deck(100)
		_check(is_equal_approx(map.selected_deck, map.discovered_decks.back()), "Deck browsing did not select the discovered upper deck")
	var discoveries: Dictionary = visibility.discovered_rooms.duplicate()
	player.global_position = Vector3(10000, 10000, 10000)
	await create_timer(0.3).timeout
	visibility.refresh()
	_check(visibility.current_room == -1 and discoveries == visibility.discovered_rooms, "Outside rendering fallback incorrectly discovered rooms")
	_enter(ship.rooms[0], player)
	visibility.refresh()
	await _toggle_culling_key()
	_check(not visibility.enabled, "K did not disable culling")
	for room in ship.rooms:
		_check(room.is_visible_in_tree(), "Disabling culling failed to restore rooms")
	await _toggle_culling_key()
	_check(visibility.enabled, "K did not re-enable culling")
	_check(discoveries == visibility.discovered_rooms, "Changing render settings reset exploration")
	_check(ship.generate(12), "Regeneration failed")
	visibility.refresh()
	_check(visibility.discovered_rooms.size() == 1 and visibility.discovered_rooms.has(0), "Regeneration did not reset exploration to the new spawn")
	_check(visibility.current_room == 0, "Regeneration retained a stale room index")
	var status: Label = level.get_node("HUD/Status")
	var bridge := -1
	for index in range(ship.rooms.size()):
		if ship.rooms[index].room_kind == &"bridge":
			bridge = index
	_check(bridge >= 0 and status.text.contains("Bridge: reachable"), "HUD must report the reachable bridge")
	if bridge >= 0:
		var neighbor: int = ship.graph.get_point_connections(bridge)[0]
		ship.graph.disconnect_points(bridge, neighbor)
		await _toggle_culling_key()
		_check(status.text.contains("Bridge: unavailable"), "HUD reports the bridge reachable without a route")
		_check(status.text.contains("Reactor: reachable"), "Bridge disconnection changed independent reactor status")
		ship.graph.connect_points(bridge, neighbor)
		await _toggle_culling_key()
		_check(status.text.contains("Bridge: reachable"), "HUD failed to restore bridge reachability after reconnection")
	level.queue_free()
	await process_frame
	await process_frame
	if _failures == 0:
		print("PASS: room rendering, inactive lights, retained physics, discovery persistence, stair tracking, culling toggle, bridge reachability and regeneration reset")
	quit(0 if _failures == 0 else 1)
