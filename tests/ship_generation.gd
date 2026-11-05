extends SceneTree
## Run: godot --headless --path . --script res://tests/ship_generation.gd

var _failures: int = 0
var _corridor_prefabs: Dictionary = {}

func _corridor_shape(directions: Array[Vector3]) -> StringName:
	var opposite_pairs := 0
	for index in range(directions.size()):
		var direction := directions[index]
		_check(absf(direction.y) < 0.001 and maxf(absf(direction.x), absf(direction.z)) > 0.999, "Corridor sockets must point along horizontal cardinal axes")
		for other_index in range(index):
			var alignment := direction.dot(directions[other_index])
			_check(alignment < -0.999 or absf(alignment) < 0.001, "Corridor has duplicate or non-cardinal arms")
			if alignment < -0.999:
				opposite_pairs += 1
	match directions.size():
		2:
			return &"straight" if opposite_pairs == 1 else &"corner"
		3:
			_check(opposite_pairs == 1, "Three-port corridor must have T geometry")
			return &"tee"
		4:
			_check(opposite_pairs == 2, "Four-port corridor must have X geometry")
			return &"cross"
		_:
			_check(false, "Corridor must have exactly two, three, or four authored arms")
			return &"invalid"

func _verify_corridor_shape(room: ShipRoom, degree: int) -> void:
	# Read the original scene too: trimming runtime sockets cannot disguise a capped X.
	if not _corridor_prefabs.has(room.scene_file_path):
		var scene := load(room.scene_file_path) as PackedScene
		_check(scene != null, "Corridor must retain its authored scene")
		if scene == null:
			return
		var authored := scene.instantiate() as ShipRoom
		_check(authored != null, "Authored corridor must be a ShipRoom")
		if authored == null:
			return
		var positions: Array[Vector3] = []
		var directions: Array[Vector3] = []
		for socket in authored.get_doors():
			positions.append(socket.position)
			directions.append(-socket.basis.z.normalized())
		_corridor_prefabs[room.scene_file_path] = {"positions": positions, "directions": directions, "shape": _corridor_shape(directions)}
		authored.free()
	var prefab: Dictionary = _corridor_prefabs[room.scene_file_path]
	var sockets := room.get_doors()
	_check(prefab.positions.size() == degree, "Authored corridor arm count must equal its connected degree")
	_check(sockets.size() == prefab.positions.size(), "Generated corridor must preserve all authored sockets")
	var connected_directions: Array[Vector3] = []
	for index in range(sockets.size()):
		var socket := sockets[index]
		_check(socket.peer != null, "Corridor contains an unused, blocked spare arm")
		if socket.peer:
			connected_directions.append(-socket.basis.z.normalized())
		if index < prefab.positions.size():
			_check(socket.position.distance_to(prefab.positions[index]) < 0.001, "Generated corridor moved an authored socket")
			_check((-socket.basis.z.normalized()).dot(prefab.directions[index]) > 0.999, "Generated corridor rotated an authored socket")
	_check(_corridor_shape(connected_directions) == prefab.shape, "Connected directions do not match the authored straight, corner, T, or X corridor")

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures += 1
		push_error(message)

func _signature(ship: ShipGenerator) -> Array:
	var result: Array = []
	for room in ship.rooms:
		result.append([room.scene_file_path, room.transform])
	result.append(ship.connections.duplicate(true))
	return result

func _is_transit(room: ShipRoom) -> bool:
	return room.room_kind in [&"corridor", &"stairs"]

func _doors_below(node: Node) -> Array[Node3D]:
	var result: Array[Node3D] = []
	if node is Node3D and node.has_method("activate") and node.has_method("set_active"):
		result.append(node)
	for child in node.get_children():
		result.append_array(_doors_below(child))
	return result

func _verify_layout(ship: ShipGenerator) -> void:
	_check(ship.rooms.size() == ship.room_count, "Requested room count not reached")
	_check(ship.rooms[0].room_kind == &"airlock", "Entrance must be the airlock")
	var kinds: Dictionary = {}
	var bridge_index := -1
	var reactor_index := -1
	var socket_connections := 0
	var expected_doors := 0
	var branches := 0
	for index in range(ship.rooms.size()):
		var room := ship.rooms[index]
		kinds[room.room_kind] = kinds.get(room.room_kind, 0) + 1
		if room.room_kind == &"bridge":
			bridge_index = index
		if room.room_kind == &"reactor":
			reactor_index = index
		var neighbors := ship.graph.get_point_connections(index)
		_check(not ship.graph.get_id_path(0, index).is_empty(), "Disconnected room")
		if room.room_kind in [&"airlock", &"bridge", &"reactor"]:
			_check(neighbors.size() == 1, "Entrance and required destinations must not become through passages")
		if neighbors.size() >= 3:
			branches += 1
		if _is_transit(room):
			_check(neighbors.size() >= 2, "Corridor ends without reaching a room or reconnecting to the network")
		if room.room_kind == &"corridor":
			_verify_corridor_shape(room, neighbors.size())
		var bounds: AABB = room.transform * room.bounds
		for other_index in range(index):
			var other := ship.rooms[other_index]
			_check(not bounds.grow(-0.006).intersects(other.transform * other.bounds), "Overlapping room shells")
		for socket in room.get_doors():
			_check(socket.position.dot(-socket.basis.z) > 0.0, "Door socket points into its room instead of outward")
			if socket.peer:
				socket_connections += 1
				_check(socket.peer.peer == socket, "Non-reciprocal socket connection")
				_check(socket.global_position.distance_to(socket.peer.global_position) < 0.001, "Door positions do not match")
				_check(socket.global_basis.z.dot(socket.peer.global_basis.z) < -0.999, "Doors do not face each other")
				_check(not socket.has_node("Wall") and not socket.has_node("SealedExit"), "Connected opening is walled off")
			else:
				_check(room.room_kind != &"corridor", "Only non-corridor rooms may have unused wall-filled sockets")
				_check(_doors_below(socket).is_empty(), "Unused opening has a fake working door")
				_check(not socket.has_node("Door") and not socket.has_node("SealedExit"), "Unused opening looks like a sealed door")
				var wall := socket.get_node_or_null("Wall") as CSGBox3D
				_check(wall != null, "Unused opening must have a plain wall")
				if wall:
					_check(wall.visible and wall.use_collision, "Unused wall must be solid and visible")
					_check(wall.size.x >= socket.opening_size.x and wall.size.y >= socket.opening_size.y, "Wall does not fill the unused opening")
					_check(absf(wall.position.z - wall.size.z * 0.5) < 0.001, "Unused wall is not flush with the room shell")
	for edge in ship.connections:
		var room_a := ship.rooms[edge.room_a]
		var room_b := ship.rooms[edge.room_b]
		var a := room_a.get_doors()[edge.door_a]
		var b := room_b.get_doors()[edge.door_b]
		_check(a.peer == b and b.peer == a, "Published connection does not match socket peers")
		_check(ship.graph.are_points_connected(edge.room_a, edge.room_b), "Published connection missing from graph")
		var doors := _doors_below(a)
		doors.append_array(_doors_below(b))
		if _is_transit(room_a) and _is_transit(room_b):
			_check(doors.is_empty(), "Corridor joins must remain open without doors")
		else:
			expected_doors += 1
			_check(doors.size() == 1, "Destination connection must contain exactly one working door")
	_check(socket_connections == ship.connections.size() * 2, "Socket and published connection counts disagree")
	_check(ship.connections.size() >= ship.rooms.size() - 1, "Room network lacks enough connections")
	_check(_doors_below(ship).size() == expected_doors, "Stray preview or duplicate door remains in the ship")
	_check(kinds.get(&"bridge", 0) == 1, "Ship must contain exactly one bridge")
	_check(kinds.get(&"reactor", 0) == 1, "Ship must contain exactly one reactor")
	if bridge_index >= 0:
		_check(not ship.graph.get_id_path(0, bridge_index).is_empty(), "Bridge must be reachable")
	if reactor_index >= 0:
		_check(not ship.graph.get_id_path(0, reactor_index).is_empty(), "Reactor must be reachable")
	if ship.room_count >= 10:
		_check(branches >= maxi(2, floori(ship.room_count / 12.0)), "Layout needs multiple real junctions, not one hallway")
		var footprint: AABB = ship.rooms[0].transform * ship.rooms[0].bounds
		for room in ship.rooms:
			footprint = footprint.merge(room.transform * room.bounds)
		_check(minf(footprint.size.x, footprint.size.z) >= maxf(footprint.size.x, footprint.size.z) * 0.5, "Layout is stretched into a single corridor")

func _door_crossing(socket: DoorSocket) -> Transform3D:
	return Transform3D(Basis.IDENTITY, socket.global_position + socket.global_basis.z.normalized() * 1.5)

func _wait_for_doors() -> void:
	await create_timer(1.6).timeout
	await physics_frame
	await physics_frame

func _verify_corridor_passage(ship: ShipGenerator, player: CharacterBody3D) -> void:
	# Doors are open here. Exercise the real capsule through every authored arm,
	# including both legs of a corner, rather than checking socket metadata alone.
	for room in ship.rooms:
		if room.room_kind != &"corridor":
			continue
		# Authored trim must fit the reserved volume; exclude generated moving
		# doors under Doors, which intentionally rise above the room when open.
		var shell := room.get_node("Airlock")
		var geometry: Array[Node] = [shell]
		geometry.append_array(shell.find_children("*", "CSGShape3D", true, false))
		for shape in geometry:
			if not shape.is_root_shape():
				continue
			var meshes: Array = shape.get_meshes()
			if meshes.is_empty():
				continue
			var placement: Transform3D = room.global_transform.affine_inverse() * shape.global_transform * meshes[0]
			var actual_bounds: AABB = placement * meshes[1].get_aabb()
			_check(room.bounds.grow(0.02).encloses(actual_bounds), "Corridor decoration exceeds its reserved room volume")
		var start := Transform3D(Basis.IDENTITY, room.global_position)
		var directions: Array[Vector3] = []
		for socket in room.get_doors():
			var outward := -socket.global_basis.z.normalized()
			var beyond_opening := socket.global_position + outward * 0.75
			_check(not player.test_move(start, beyond_opening - start.origin), "Corridor center cannot physically reach a connected opening")
			directions.append(-socket.basis.z.normalized())
		for direction in [Vector3.FORWARD, Vector3.RIGHT, Vector3.BACK, Vector3.LEFT]:
			var has_arm := false
			for socket_direction in directions:
				has_arm = has_arm or direction.dot(socket_direction) > 0.999
			if has_arm:
				continue
			var face_distance: float
			if direction.x > 0.0:
				face_distance = room.bounds.end.x
			elif direction.x < 0.0:
				face_distance = -room.bounds.position.x
			elif direction.z > 0.0:
				face_distance = room.bounds.end.z
			else:
				face_distance = -room.bounds.position.z
			var motion: Vector3 = room.global_basis * direction * (face_distance + 0.75)
			var collision := KinematicCollision3D.new()
			var blocked := player.test_move(start, motion, collision)
			_check(blocked, "Corridor shell has an unauthored extra opening")
			if blocked:
				var collider := collision.get_collider() as Node
				_check(collider != null and room.is_ancestor_of(collider), "An adjacent room hides an unauthored corridor opening")

func _verify_door_motion(ship: ShipGenerator, player: CharacterBody3D, check_proximity: bool) -> void:
	# Use the production player's real capsule, without input/gravity moving it.
	# Sweep through each entrance: closing must obstruct it; opening must clear it.
	var entrances: Array[Dictionary] = []
	for room in ship.rooms:
		for socket in room.get_doors():
			for door in _doors_below(socket):
				entrances.append({"socket": socket, "door": door, "closed": door.global_position})
	player.global_position = Vector3(0, 10000, 0)
	await physics_frame
	await physics_frame
	for entrance in entrances:
		var socket: DoorSocket = entrance.socket
		var collision := KinematicCollision3D.new()
		var blocked := player.test_move(_door_crossing(socket), -socket.global_basis.z.normalized() * 3.0, collision)
		_check(blocked, "Closed destination door does not block the player")
		if blocked:
			var collider := collision.get_collider() as Node
			_check(collider != null and entrance.door.is_ancestor_of(collider), "An unrelated obstruction replaces the closed door")
		entrance.door.set_active(true)
	await _wait_for_doors()
	_verify_corridor_passage(ship, player)
	for entrance in entrances:
		var socket: DoorSocket = entrance.socket
		_check(entrance.door.global_position.y > entrance.closed.y + socket.opening_size.y * 0.5, "Door did not physically rise when opened")
		_check(not player.test_move(_door_crossing(socket), -socket.global_basis.z.normalized() * 3.0), "Open destination door still blocks the real player")
		entrance.door.set_active(false)
	await _wait_for_doors()
	for entrance in entrances:
		_check(entrance.door.global_position.distance_to(entrance.closed) < 0.04, "Door did not return to its closed position")
	if check_proximity and not entrances.is_empty():
		var entrance := entrances[0]
		var socket: DoorSocket = entrance.socket
		player.global_transform = _door_crossing(socket)
		await _wait_for_doors()
		_check(entrance.door.global_position.y > entrance.closed.y + socket.opening_size.y * 0.5, "Approaching player did not automatically open the door")
		var crossing := -socket.global_basis.z.normalized() * 3.0
		_check(player.move_and_collide(crossing) == null, "Player cannot physically walk through the automatically opened door")
		player.global_position = Vector3(0, 10000, 0)
		await _wait_for_doors()
		_check(entrance.door.global_position.distance_to(entrance.closed) < 0.04, "Door did not close after the player left")

func _run() -> void:
	var player: CharacterBody3D = preload("res://New Controller/SourceFPSController.tscn").instantiate()
	player.position = Vector3(0, 10000, 0)
	root.add_child(player)
	player.set_process(false)
	player.set_physics_process(false)
	player.set_process_input(false)
	player.set_process_unhandled_input(false)
	var ship := ShipGenerator.new()
	ship.generate_on_ready = false
	root.add_child(ship)
	var bridge_depths: Dictionary = {}
	var has_remote_bridge := false
	# Keep a random case as well: zero must expose a seed that can be replayed.
	for seed_value in [1, 3, 12, 42, 0]:
		if not ship.generate(seed_value):
			quit(1)
			return
		_verify_layout(ship)
		if seed_value != 0:
			for index in range(ship.rooms.size()):
				if ship.rooms[index].room_kind == &"bridge":
					var depth := ship.graph.get_id_path(0, index).size()
					bridge_depths[depth] = true
					has_remote_bridge = has_remote_bridge or depth > 3
		await _verify_door_motion(ship, player, seed_value == 1)
		var before := _signature(ship)
		_check(ship.used_seed > 0, "Generated seed must be replayable")
		if not ship.generate(ship.used_seed):
			quit(1)
			return
		_check(before == _signature(ship), "Seed replay changed layout or connections")
		await process_frame
	_check(bridge_depths.size() > 1, "Bridge remains pinned to one entrance-relative location across seeds")
	_check(has_remote_bridge, "Bridge never moves beyond the entrance junction")
	for count in [4, 128]:
		ship.room_count = count
		if not ship.generate(42):
			quit(1)
			return
		_verify_layout(ship)
		await _verify_door_motion(ship, player, false)
	ship.queue_free()
	player.queue_free()
	await process_frame
	await process_frame
	if _failures == 0:
		print("PASS: branching room network, reachable bridge/reactor, deterministic replay, 4/128 rooms, bounds/alignment, authored straight/corner/T/X geometry, no spare corridor arms, solid unused room walls, corridor capsule passage, real door motion/collision and player passage")
	quit(0 if _failures == 0 else 1)
