extends SceneTree
## Run: godot --headless --path . --script res://tests/room_visibility_sightlines.gd

const CHAIN_LENGTH := 7
const ROOM_BOUNDS := AABB(Vector3(-5, -2.25, -5), Vector3(10, 4.5, 10))

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures += 1
		push_error(message)


func _new_fixture(explicit_camera: bool = true) -> Dictionary:
	# A square, real viewport makes aperture/frustum tests independent of the
	# editor window, headless window size, and any other fixture's current camera.
	var viewport := SubViewport.new()
	viewport.name = "SightlineViewport"
	viewport.size = Vector2i(800, 800)
	viewport.own_world_3d = true
	var level := Node3D.new()
	level.name = "Fixture"
	viewport.add_child(level)
	var ship := ShipGenerator.new()
	ship.name = "Ship"
	ship.generate_on_ready = false
	level.add_child(ship)
	var player := CharacterBody3D.new()
	player.name = "Player"
	level.add_child(player)
	var camera := Camera3D.new()
	camera.name = "Camera"
	camera.fov = 75.0
	camera.near = 0.3
	camera.far = 500.0
	camera.current = true
	level.add_child(camera)
	var visibility := RoomVisibility.new()
	visibility.name = "RoomVisibility"
	visibility.ship_path = NodePath("../Ship")
	visibility.player_path = NodePath("../Player")
	if explicit_camera:
		visibility.camera_path = NodePath("../Camera")
	visibility.update_interval = 0.01
	level.add_child(visibility)
	return {
		"viewport": viewport, "ship": ship, "player": player,
		"camera": camera, "visibility": visibility, "doors": [],
	}


func _add_room(fixture: Dictionary, position: Vector3, bounds: AABB = ROOM_BOUNDS, kind: StringName = &"room") -> int:
	var ship: ShipGenerator = fixture.ship
	var index := ship.rooms.size()
	var room := ShipRoom.new()
	room.name = "Room%02d" % index
	room.position = position
	room.bounds = bounds
	room.room_kind = kind
	var sockets := Node3D.new()
	sockets.name = "Doors"
	room.add_child(sockets)
	# Real geometry and physics remain attached when the room root is hidden.
	var floor_mesh := BoxMesh.new()
	floor_mesh.size = Vector3(bounds.size.x, 0.2, bounds.size.z)
	var floor_visual := MeshInstance3D.new()
	floor_visual.name = "Floor"
	floor_visual.mesh = floor_mesh
	floor_visual.position = Vector3(bounds.get_center().x, bounds.position.y + 0.1, bounds.get_center().z)
	room.add_child(floor_visual)
	var floor_body := StaticBody3D.new()
	floor_body.position = floor_visual.position
	var floor_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = floor_mesh.size
	floor_shape.shape = box
	floor_body.add_child(floor_shape)
	room.add_child(floor_body)
	ship.add_child(room)
	ship.rooms.append(room)
	ship.graph.add_point(index, position)
	return index


func _add_socket(room: ShipRoom, point: Vector3, outward: Vector3) -> DoorSocket:
	var container: Node3D = room.get_node("Doors")
	var socket := DoorSocket.new()
	socket.name = "Port%02d" % container.get_child_count()
	socket.transform = room.transform.affine_inverse() * Transform3D(Basis.looking_at(outward, Vector3.UP), point)
	socket.opening_size = Vector2(5.4, 3.6)
	container.add_child(socket)
	return socket


func _connect(fixture: Dictionary, a: int, b: int, point: Vector3, outward: Vector3, glass_door: bool = false) -> void:
	var ship: ShipGenerator = fixture.ship
	var room_a := ship.rooms[a]
	var room_b := ship.rooms[b]
	var door_a := room_a.get_doors().size()
	var door_b := room_b.get_doors().size()
	var socket_a := _add_socket(room_a, point, outward)
	var socket_b := _add_socket(room_b, point, -outward)
	socket_a.peer = socket_b
	socket_b.peer = socket_a
	ship.graph.connect_points(a, b)
	ship.connections.append({"room_a": a, "door_a": door_a, "room_b": b, "door_b": door_b})
	if glass_door:
		# Same runtime root, authored glass asset, dimensions and collision as the
		# generator, deliberately held CLOSED rather than replacing it with a stub.
		var door := Node3D.new()
		door.name = "Door"
		door.set_script(ShipGenerator.DOOR_SCRIPT)
		door.set("auto_open", false)
		door.set("open_height", socket_a.opening_size.y + 0.4)
		var visual := ShipGenerator.DOOR_SCENE.instantiate() as Node3D
		visual.name = "Visual"
		visual.scale = Vector3(socket_a.opening_size.x / 1.5, socket_a.opening_size.y / 2.0, 0.3)
		door.add_child(visual)
		socket_a.add_child(door)
		fixture.doors.append(door)


func _set_view(fixture: Dictionary, position: Vector3, direction: Vector3, move_player: bool = true) -> void:
	var ship: ShipGenerator = fixture.ship
	var player: CharacterBody3D = fixture.player
	var camera: Camera3D = fixture.camera
	if move_player:
		player.global_position = ship.to_global(position)
	camera.global_transform = ship.global_transform * Transform3D(Basis.looking_at(direction.normalized(), Vector3.UP), position)


func _mount(fixture: Dictionary, position: Vector3 = Vector3.ZERO, direction: Vector3 = Vector3.FORWARD) -> void:
	var viewport: SubViewport = fixture.viewport
	root.add_child(viewport)
	var camera: Camera3D = fixture.camera
	camera.make_current()
	_set_view(fixture, position, direction)
	var visibility: RoomVisibility = fixture.visibility
	visibility.reset()


func _dispose(fixture: Dictionary) -> void:
	var viewport: SubViewport = fixture.viewport
	viewport.queue_free()
	await process_frame
	await process_frame


func _check_room(fixture: Dictionary, index: int, expected: bool, message: String) -> void:
	var visibility: RoomVisibility = fixture.visibility
	var ship: ShipGenerator = fixture.ship
	_check(visibility.active_rooms.has(index) == expected, "%s (active room %d)" % [message, index])
	_check(ship.rooms[index].is_visible_in_tree() == expected, "%s (render root %d)" % [message, index])


func _check_chain(fixture: Dictionary, message: String) -> void:
	for index in range(CHAIN_LENGTH):
		_check_room(fixture, index, true, message)


func _chain_fixture(rise: float = 0.0, explicit_camera: bool = true) -> Dictionary:
	var fixture := _new_fixture(explicit_camera)
	var bounds := ROOM_BOUNDS
	if rise != 0.0:
		bounds.size.y = 8.0
	for index in range(CHAIN_LENGTH):
		_add_room(fixture, Vector3(0, rise * index, -10.0 * index), bounds, &"stairs" if rise != 0.0 else &"room")
	for index in range(CHAIN_LENGTH - 1):
		_connect(fixture, index, index + 1, Vector3(0, rise * (index + 1), -5.0 - 10.0 * index), Vector3.FORWARD, true)
	return fixture


func _test_long_chain_and_turning() -> void:
	var fixture := _chain_fixture()
	# This side opening IS in the camera's original frustum, but is entirely
	# outside the narrower window inherited through the z=-25 doorway.
	var branch := _add_room(fixture, Vector3(10, 0, -30))
	_connect(fixture, 3, branch, Vector3(5, 0, -30), Vector3.RIGHT)
	_mount(fixture)
	var visibility: RoomVisibility = fixture.visibility
	var ship: ShipGenerator = fixture.ship
	var camera: Camera3D = fixture.camera
	var player: CharacterBody3D = fixture.player
	_check(camera.is_position_in_frustum(ship.to_global(Vector3(5, 0, -30))), "Branch fixture must be inside the original camera frustum")
	_check_chain(fixture, "Seven aligned rooms must remain visible beyond the old two-hop limit")
	_check_room(fixture, branch, false, "A perpendicular portal outside inherited doorway sightlines must be hidden")
	_check(visibility.current_room == 0 and visibility.discovered_rooms.size() == 1 and visibility.discovered_rooms.has(0), "Seeing the full chain must discover only the occupied room")
	for value in fixture.doors:
		var door: Node3D = value
		_check(door.position.is_equal_approx(Vector3.ZERO), "A transparent fixture door must really be closed")
		var glass := door.get_node("Visual/InnerAirlockDoor/CSGBox3D3") as CSGBox3D
		var material := glass.material as StandardMaterial3D
		_check(glass.use_collision and material != null and material.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA and material.albedo_color.a < 1.0, "Fixture must use the actual collidable transparent door asset")
	var player_before := player.global_transform
	var camera_before := camera.global_position
	var closed_door: Node3D = fixture.doors[0]
	_set_view(fixture, Vector3.ZERO, Vector3.BACK, false)
	visibility.refresh()
	_check_room(fixture, 0, true, "Turning away must preserve the current room")
	for index in range(2, CHAIN_LENGTH):
		_check_room(fixture, index, false, "Turning away must cull the distant forward chain")
	_set_view(fixture, Vector3.ZERO, Vector3.FORWARD, false)
	# No refresh/reset and no player movement: camera rotation alone must cause
	# the normal physics updater to replace the culled set.
	for _frame in range(4):
		await physics_frame
	_check(player.global_transform.is_equal_approx(player_before) and camera.global_position.is_equal_approx(camera_before), "Automatic rotation regression must not move player or camera")
	_check_chain(fixture, "Stationary-player camera rotation must automatically restore the chain")
	_check_room(fixture, branch, false, "Camera refresh must keep the around-corner branch culled")
	_check(closed_door.position.is_equal_approx(Vector3.ZERO), "Visibility must see through a door while its actual animation stays closed")
	# Projection and viewport changes also matter with an unchanged camera pose.
	_set_view(fixture, Vector3.ZERO, Vector3(0.2, 0, -1), false)
	visibility.refresh()
	_check_chain(fixture, "Wide projection must contain the slightly off-axis chain")
	camera.fov = 15.0
	for _frame in range(4):
		await physics_frame
	_check_room(fixture, CHAIN_LENGTH - 1, false, "A stationary camera's narrower projection must automatically cull the distant chain")
	var viewport: SubViewport = fixture.viewport
	viewport.size = Vector2i(1600, 400)
	for _frame in range(4):
		await physics_frame
	_check_chain(fixture, "Viewport aspect changes must automatically restore the horizontal sightline")
	viewport.size = Vector2i(800, 800)
	camera.fov = 75.0
	_set_view(fixture, Vector3.ZERO, Vector3.FORWARD, false)
	for _frame in range(4):
		await physics_frame
	# Opening the same real asset must not change the doorway's visibility policy.
	closed_door.call("set_active", true)
	for _frame in range(4):
		await process_frame
	_check(closed_door.position.y > 0.0, "Real door animation must run in the fixture")
	visibility.refresh()
	_check_chain(fixture, "Transparent door animation must never act as an occluder")
	await _dispose(fixture)


func _test_near_plane_crossing() -> void:
	var fixture := _chain_fixture()
	_mount(fixture)
	var visibility: RoomVisibility = fixture.visibility
	for z in [-4.7, -4.98, -5.0, -5.02, -5.3]:
		_set_view(fixture, Vector3(0, 0, z), Vector3.FORWARD)
		visibility.refresh()
		_check_room(fixture, 0, true, "Crossing the near-clipped doorway must preserve its source room")
		_check_room(fixture, 1, true, "Crossing the near-clipped doorway must preserve its destination room")
		_check_room(fixture, CHAIN_LENGTH - 1, true, "Near-plane clipping must not black out the aligned distant chain")
	_check(visibility.current_room == 1, "Door crossing fixture must actually enter the neighboring room")
	_check(visibility.discovered_rooms.size() == 2 and visibility.discovered_rooms.has(0) and visibility.discovered_rooms.has(1), "Door crossing must discover only rooms actually entered")
	await _dispose(fixture)


func _test_transformed_raised_ports() -> void:
	# Each stair-like room enters at local y=0 and exits at local y=2. The
	# camera ray y=1-z/5 passes through every elevated doorway center.
	var fixture := _chain_fixture(2.0, false)
	var ship: ShipGenerator = fixture.ship
	ship.transform = Transform3D(Basis(Vector3.UP, 0.73), Vector3(43, 8, -29))
	_mount(fixture, Vector3(0, 1, 0), Vector3(0, 0.2, -1))
	var visibility: RoomVisibility = fixture.visibility
	var camera: Camera3D = fixture.camera
	_check(camera.get_viewport().get_camera_3d() == camera, "Raised-port fixture must exercise the real current viewport camera")
	_check_chain(fixture, "A transformed ship's raised ports must retain the aligned sightline")
	_check(visibility.current_room == 0 and visibility.discovered_rooms.size() == 1, "Raised sightlines must not discover remote stair rooms")
	# A 63-degree downward pitch puts even the 75-degree frustum's top ray
	# more than 25 degrees below horizontal, outside every raised aperture.
	_set_view(fixture, Vector3(0, 1, 0), Vector3(0, -2, -1), false)
	visibility.refresh()
	_check_room(fixture, CHAIN_LENGTH - 1, false, "Looking below the raised portals must cull the remote upper chain")
	_set_view(fixture, Vector3(0, 1, 0), Vector3(0, 0.2, -1), false)
	for _frame in range(4):
		await physics_frame
	_check_chain(fixture, "Pitch-only camera movement must restore transformed elevated sightlines")
	await _dispose(fixture)


func _test_multiple_approaches(reverse_order: bool) -> void:
	var fixture := _new_fixture()
	# A real spatial diamond: root -> left/right -> shared -> tail. The root
	# extends behind the camera so BOTH parallel lanes have a continuous ray.
	# Only the right approach to shared can see its right-hand tail doorway.
	_add_room(fixture, Vector3.ZERO, AABB(Vector3(-10, -2.25, -5), Vector3(20, 4.5, 20)))
	_add_room(fixture, Vector3(-5, 0, -10))
	_add_room(fixture, Vector3(5, 0, -10))
	_add_room(fixture, Vector3(0, 0, -20), AABB(Vector3(-10, -2.25, -5), Vector3(20, 4.5, 10)))
	_add_room(fixture, Vector3(5, 0, -30))
	var lanes: Array[int] = [1, 2]
	if reverse_order:
		lanes.reverse()
	for lane in lanes:
		var x := -5.0 if lane == 1 else 5.0
		_connect(fixture, 0, lane, Vector3(x, 0, -5), Vector3.FORWARD)
		_connect(fixture, lane, 3, Vector3(x, 0, -15), Vector3.FORWARD)
	_connect(fixture, 3, 4, Vector3(5, 0, -25), Vector3.FORWARD)
	_mount(fixture, Vector3(0, 0, 10))
	var visibility: RoomVisibility = fixture.visibility
	for _iteration in range(8):
		visibility.refresh()
		for index in range(5):
			_check_room(fixture, index, true, "A cyclic graph must terminate and retain the valid second aperture path (reverse=%s)" % reverse_order)
	_check(visibility.active_rooms.size() == 5, "Cycle traversal must publish each room once, not duplicate path visits")
	_check(visibility.current_room == 0 and visibility.discovered_rooms.size() == 1, "Cycle visibility must not change player containment or discovery")
	await _dispose(fixture)


func _run() -> void:
	await _test_long_chain_and_turning()
	await _test_near_plane_crossing()
	await _test_transformed_raised_ports()
	await _test_multiple_approaches(false)
	await _test_multiple_approaches(true)
	if _failures == 0:
		print("PASS: unbounded doorway sightlines, inherited branch clipping, stationary camera updates, closed glass doors, near-plane crossings, transformed raised ports and cyclic multiple approaches")
	quit(0 if _failures == 0 else 1)
