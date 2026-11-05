class_name ShipGenerator
extends Node3D
## Plans a connected ship with socket snapping before instantiating its geometry.

signal generation_completed
signal generation_failed(reason: String)

const DOOR_SCRIPT = preload("res://util/door_airlock.gd")
const DOOR_SCENE = preload("res://util/door_airlock.tscn")
const SHORT_CORRIDOR_SCENE = preload("res://ship/corridor_short.tscn")
const ROOM_SCENES: Array[PackedScene] = [
	preload("res://ship/segment_airlock.tscn"),
	preload("res://ship/corridor.tscn"),
	preload("res://ship/corridorL.tscn"),
	preload("res://ship/corridorR.tscn"),
	preload("res://ship/corridorT.tscn"),
	preload("res://ship/corridorX.tscn"),
	preload("res://ship/segment_bridge.tscn"),
	preload("res://ship/segment_reactor.tscn"),
	preload("res://ship/segment_armory.tscn"),
	preload("res://ship/segment_bathroom.tscn"),
	preload("res://ship/segment_conference.tscn"),
	preload("res://ship/segment_lab_1.tscn"),
	preload("res://ship/segment_lab_2.tscn"),
	preload("res://ship/segment_lab_3.tscn"),
	preload("res://ship/segment_mess_room.tscn"),
	preload("res://ship/segment_office_1.tscn"),
	preload("res://ship/segment_office_2.tscn"),
	preload("res://ship/segment_office_3.tscn"),
	preload("res://ship/segment_quarters.tscn"),
	preload("res://ship/segment_stairs.tscn"),
	preload("res://ship/segment_storage_1.tscn"),
	preload("res://ship/segment_storage_2.tscn"),
	preload("res://ship/segment_storage_3.tscn"),
]

@export_range(4, 128) var room_count: int = 24
@export var generation_seed: int = 0
@export var generate_on_ready: bool = true
## Extra authored prefabs join the built-in catalog using the same socket contract.
@export var additional_rooms: Array[PackedScene] = []

var rooms: Array[ShipRoom] = []
var graph := AStar3D.new()
var used_seed: int = 0
var last_error: String = ""
## Each edge identifies the connected rooms and their door indices.
var connections: Array[Dictionary] = []

var _templates: Array[Dictionary] = []
var _layout: Array[Dictionary] = []
var _edges: Array[Dictionary] = []
var _rng := RandomNumberGenerator.new()
var _generated: Node3D

func _ready() -> void:
	if generate_on_ready:
		generate()


func generate(seed_value: int = -1) -> bool:
	last_error = ""
	if room_count < 4:
		return _fail("Room count must be at least 4: airlock, junction, bridge, reactor.")
	if not _load_templates():
		return false
	var requested_seed := generation_seed if seed_value < 0 else seed_value
	if requested_seed == 0:
		_rng.randomize()
		# Keep generated seeds outside generate()'s negative/default and zero/random sentinels.
		_rng.seed = _rng.randi_range(1, 2147483647)
	else:
		_rng.seed = requested_seed
	var planned_seed := _rng.seed
	var airlock := _find_kind(&"airlock")
	var bridge := _find_kind(&"bridge")
	var reactor := _find_kind(&"reactor")
	var junction := -1
	for index in range(_templates.size()):
		if _templates[index].kind == &"corridor" and _templates[index].doors.size() >= 3:
			junction = index
	if airlock < 0 or bridge < 0 or reactor < 0 or junction < 0:
		return _fail("Catalog needs an airlock, bridge, reactor and branching corridor.")
	# Layout attempts remain detached until every destination and corridor fits.
	for attempt in range(32):
		if _plan_layout(airlock, junction, bridge, reactor):
			used_seed = planned_seed
			_commit_layout()
			generation_completed.emit()
			return true
	return _fail("Could not fit %d rooms after 32 layout attempts; reduce room_count or check prefab bounds/sockets." % room_count)

func _plan_layout(airlock: int, junction: int, bridge: int, reactor: int) -> bool:
	_layout.clear()
	_edges.clear()
	_append_room(airlock, Transform3D.IDENTITY)
	var entrance := Vector2i(0, _rng.randi_range(0, _templates[airlock].doors.size() - 1))
	if _attach(junction, entrance).x < 0:
		return false
	# Reserve both required destinations, but choose the bridge's attachment
	# from the completed network rather than pinning it to the entrance.
	while _layout.size() < room_count - 2:
		var furnished := _weighted_candidates()
		var transit := _weighted_candidates(true)
		var placed := false
		for port in _growth_ports():
			var source: Dictionary = _layout[port.x]
			var source_is_transit: bool = _templates[source.template].kind in [&"corridor", &"stairs"]
			var candidates: Array[int] = []
			if source_is_transit:
				# Furnished rooms can themselves have several exits. Expand from
				# different rooms instead of sending every branch down one spine.
				var allow_transit := int(source.transit_run) < 2
				if allow_transit and _rng.randf() < 0.35:
					candidates.append_array(transit)
				candidates.append_array(furnished)
				if allow_transit and candidates.size() == furnished.size():
					candidates.append_array(transit)
			else:
				candidates.append_array(transit)
			for candidate in candidates:
				var is_transit: bool = _templates[candidate].kind in [&"corridor", &"stairs"]
				# A corridor consumes two slots: the passage and a real room
				# beyond it. Never spend the final slot on an empty corridor tip.
				if is_transit and room_count - 2 - _layout.size() < 2:
					continue
				var previous_rooms := _layout.size()
				var previous_edges := _edges.size()
				var entry := _attach(candidate, port)
				if entry.x < 0:
					continue
				if is_transit and not _finish_corridor(entry.x, furnished):
					# Undo the entire proposed stub before trying another fit.
					_layout.resize(previous_rooms)
					_edges.resize(previous_edges)
					continue
				placed = true
				break
			if placed:
				break
		if not placed:
			return false
	if not _attach_destination(bridge, true):
		return false
	if not _attach_destination(reactor):
		return false
	_connect_touching_ports()
	if not _normalize_junctions():
		return false
	# Reject the old failure mode: one stretched hallway with cosmetic branches.
	if room_count >= 10:
		var degrees: Dictionary = {}
		for edge in _edges:
			degrees[edge.room_a] = int(degrees.get(edge.room_a, 0)) + 1
			degrees[edge.room_b] = int(degrees.get(edge.room_b, 0)) + 1
		var branches :=  0
		for degree in degrees.values():
			if degree >= 3:
				branches += 1
		if branches < maxi(2, floori(room_count / 12.0)):
			return false
		var footprint: AABB = _layout[0].bounds
		for placed in _layout:
			footprint = footprint.merge(placed.bounds)
		if minf(footprint.size.x, footprint.size.z) < maxf(footprint.size.x, footprint.size.z) * 0.5:
			return false
	return _validate_layout()

func _finish_corridor(index: int, destinations: Array[int]) -> bool:
	for port in _free_ports():
		if port.x != index:
			continue
		for destination in destinations:
			if _attach(destination, port).x >= 0:
				return true
	return false

func _attach_destination(template_index: int, random_location: bool = false) -> bool:
	var ports := _free_ports() if random_location else _growth_ports()
	while not ports.is_empty():
		var index := _rng.randi_range(0, ports.size() - 1) if random_location else 0
		var port := ports[index]
		ports.remove_at(index)
		if _attach(template_index, port).x >= 0:
			return true
	return false

func _free_ports() -> Array[Vector2i]:
	var used: Dictionary = {}
	for edge in _edges:
		used[Vector2i(edge.room_a, edge.door_a)] = true
		used[Vector2i(edge.room_b, edge.door_b)] = true
	var result: Array[Vector2i] = []
	for index in range(_layout.size()):
		var template: Dictionary = _templates[_layout[index].template]
		if template.kind in [&"airlock", &"bridge", &"reactor"]:
			continue
		for door in range(template.doors.size()):
			var port := Vector2i(index, door)
			if not used.has(port):
				result.append(port)
	return result

func _growth_ports() -> Array[Vector2i]:
	var ports := _free_ports()
	var scores: Dictionary = {}
	for port in ports:
		var room: Dictionary = _layout[port.x]
		var socket: Transform3D = _templates[room.template].doors[port.y].transform
		var target: Transform3D = room.transform * socket
		# Prefer nearby unused space, with seeded variation. Never prefer the
		# latest room simply because it was the previous growth tip.
		scores[port] = target.origin.length() * 0.025 + _rng.randf() * 2.0
	ports.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return scores[a] < scores[b])
	return ports

func _connect_touching_ports() -> void:
	var ports := _free_ports()
	var linked: Dictionary = {}
	for index in range(ports.size()):
		var a := ports[index]
		if linked.has(a):
			continue
		var room_a: Dictionary = _layout[a.x]
		var socket_a: Dictionary = _templates[room_a.template].doors[a.y]
		var transform_a: Transform3D = room_a.transform * socket_a.transform
		for other_index in range(index + 1, ports.size()):
			var b := ports[other_index]
			if a.x == b.x or linked.has(b):
				continue
			var room_b: Dictionary = _layout[b.x]
			var socket_b: Dictionary = _templates[room_b.template].doors[b.y]
			var transform_b: Transform3D = room_b.transform * socket_b.transform
			if transform_a.origin.distance_to(transform_b.origin) < 0.005 and transform_a.basis.z.dot(transform_b.basis.z) < -0.999 and (socket_a.size as Vector2).is_equal_approx(socket_b.size):
				_edges.append({"room_a": a.x, "door_a": a.y, "room_b": b.x, "door_b": b.y})
				linked[a] = true
				linked[b] = true
				break

func _connected_doors(room_index: int) -> Array[int]:
	var result: Array[int] = []
	for edge in _edges:
		if edge.room_a == room_index:
			result.append(edge.door_a)
		elif edge.room_b == room_index:
			result.append(edge.door_b)
	return result

func _junction_shape(sockets: Array[Transform3D]) -> StringName:
	if sockets.size() < 2 or sockets.size() > 4:
		return &""
	for index in range(sockets.size()):
		var normal := sockets[index].basis.z.normalized()
		if absf(normal.y) > 0.001:
			return &""
		for other in range(index):
			var alignment := normal.dot(sockets[other].basis.z.normalized())
			if absf(alignment) > 0.001 and alignment > -0.999:
				return &""
	if sockets.size() == 2:
		return &"straight" if sockets[0].basis.z.normalized().dot(sockets[1].basis.z.normalized()) < -0.999 else &"elbow"
	return &"tee" if sockets.size() == 3 else &"cross"

func _same_socket(a: Transform3D, b: Transform3D) -> bool:
	return a.origin.distance_to(b.origin) < 0.005 and a.basis.z.normalized().dot(b.basis.z.normalized()) > 0.999 and a.basis.y.normalized().dot(b.basis.y.normalized()) > 0.999

func _normalize_junctions() -> bool:
	for room_index in range(_layout.size()):
		var placed: Dictionary = _layout[room_index]
		var original: Dictionary = _templates[placed.template]
		if original.kind != &"corridor":
			continue
		var connected := _connected_doors(room_index)
		var world_sockets: Array[Transform3D] = []
		for door_index in connected:
			world_sockets.append(placed.transform * original.doors[door_index].transform)
		var shape := _junction_shape(world_sockets)
		if shape == &"":
			return false
		# Complete authored corridors already have exactly the right arms.
		# In particular, keep the long straight's span and all its decoration.
		if connected.size() == original.doors.size():
			continue
		var replacement: Dictionary = {}
		for template_index in range(_templates.size()):
			var candidate: Dictionary = _templates[template_index]
			if candidate.kind != &"corridor" or candidate.doors.size() != connected.size():
				continue
			var local_sockets: Array[Transform3D] = []
			for socket in candidate.doors:
				local_sockets.append(socket.transform)
			if _junction_shape(local_sockets) != shape:
				continue
			replacement = _fit_junction(candidate, connected, world_sockets, original)
			if not replacement.is_empty():
				replacement["template"] = template_index
				break
		if replacement.is_empty():
			# Never move neighbors or seal an unused arm to disguise a bad fit.
			return false
		var remap: Dictionary = replacement.remap
		for edge in _edges:
			if edge.room_a == room_index:
				edge.door_a = remap[edge.door_a]
			if edge.room_b == room_index:
				edge.door_b = remap[edge.door_b]
		placed.template = replacement.template
		placed.transform = replacement.transform
		placed.bounds = replacement.transform * (_templates[replacement.template].bounds as AABB)
	return true

func _fit_junction(candidate: Dictionary, connected: Array[int], world_sockets: Array[Transform3D], original: Dictionary) -> Dictionary:
	for turn in range(4):
		var rotation := Basis(Vector3.UP, turn * PI * 0.5)
		for anchor in range(candidate.doors.size()):
			var placement := Transform3D(rotation, world_sockets[0].origin - rotation * (candidate.doors[anchor].transform as Transform3D).origin)
			var remap: Dictionary = {}
			var used: Dictionary = {}
			for index in range(connected.size()):
				for door_index in range(candidate.doors.size()):
					if used.has(door_index):
						continue
					var socket: Dictionary = candidate.doors[door_index]
					if not (socket.size as Vector2).is_equal_approx(original.doors[connected[index]].size):
						continue
					if _same_socket(world_sockets[index], placement * socket.transform):
						remap[connected[index]] = door_index
						used[door_index] = true
						break
			if remap.size() == connected.size():
				return {"transform": placement, "remap": remap}
	return {}

func _validate_layout() -> bool:
	var used: Dictionary = {}
	var neighbors: Dictionary = {}
	for edge in _edges:
		if edge.room_a < 0 or edge.room_a >= _layout.size() or edge.room_b < 0 or edge.room_b >= _layout.size() or edge.room_a == edge.room_b:
			return false
		var room_a: Dictionary = _layout[edge.room_a]
		var room_b: Dictionary = _layout[edge.room_b]
		var doors_a: Array = _templates[room_a.template].doors
		var doors_b: Array = _templates[room_b.template].doors
		if edge.door_a < 0 or edge.door_a >= doors_a.size() or edge.door_b < 0 or edge.door_b >= doors_b.size():
			return false
		var port_a := Vector2i(edge.room_a, edge.door_a)
		var port_b := Vector2i(edge.room_b, edge.door_b)
		if used.has(port_a) or used.has(port_b):
			return false
		var a: Transform3D = room_a.transform * doors_a[edge.door_a].transform
		var b: Transform3D = room_b.transform * doors_b[edge.door_b].transform
		if a.origin.distance_to(b.origin) >= 0.005 or a.basis.z.normalized().dot(b.basis.z.normalized()) > -0.999 or a.basis.y.normalized().dot(b.basis.y.normalized()) < 0.999:
			return false
		if not (doors_a[edge.door_a].size as Vector2).is_equal_approx(doors_b[edge.door_b].size):
			return false
		used[port_a] = true
		used[port_b] = true
		if not neighbors.has(edge.room_a):
			neighbors[edge.room_a] = []
		if not neighbors.has(edge.room_b):
			neighbors[edge.room_b] = []
		neighbors[edge.room_a].append(edge.room_b)
		neighbors[edge.room_b].append(edge.room_a)
	for index in range(_layout.size()):
		var placed: Dictionary = _layout[index]
		var template: Dictionary = _templates[placed.template]
		var degree: int = neighbors.get(index, []).size()
		if template.kind in [&"corridor", &"stairs"] and degree < 2:
			return false
		if template.kind == &"corridor":
			if degree != template.doors.size():
				return false
			var sockets: Array[Transform3D] = []
			for socket in template.doors:
				sockets.append(placed.transform * socket.transform)
			if _junction_shape(sockets) == &"":
				return false
		var bounds: AABB = placed.bounds
		for other in range(index):
			if bounds.grow(-0.005).intersects(_layout[other].bounds):
				return false
	if _layout.is_empty():
		return false
	var reached: Dictionary = {0: true}
	var pending: Array[int] = [0]
	while not pending.is_empty():
		var index: int = pending.pop_back()
		for neighbor in neighbors.get(index, []):
			if not reached.has(neighbor):
				reached[neighbor] = true
				pending.append(neighbor)
	return reached.size() == _layout.size()

func _fail(reason: String) -> bool:
	last_error = reason
	generation_failed.emit(reason)
	push_error("Ship generation: " + reason)
	return false

func _load_templates() -> bool:
	if not _templates.is_empty():
		return true
	var scenes: Array[PackedScene] = []
	scenes.append_array(ROOM_SCENES)
	scenes.append_array(additional_rooms)
	# Replacement-only: do not change growth choices or consume seeded RNG.
	scenes.append(SHORT_CORRIDOR_SCENE)
	for scene in scenes:
		if scene == null:
			_templates.clear()
			return _fail("Room catalog contains an empty scene.")
		var instance := scene.instantiate()
		if not instance is ShipRoom:
			instance.free()
			_templates.clear()
			return _fail("Room scene must have the ShipRoom script: " + scene.resource_path)
		var room := instance as ShipRoom
		var doors: Array[Dictionary] = []
		for socket in room.get_doors():
			doors.append({"transform": socket.get_parent().transform * socket.transform, "size": socket.opening_size})
		if doors.is_empty() or not room.bounds.has_volume():
			room.free()
			_templates.clear()
			return _fail("Room needs door sockets and non-empty bounds: " + scene.resource_path)
		_templates.append({"scene": scene, "kind": room.room_kind, "bounds": room.bounds, "weight": room.selection_weight, "doors": doors})
		room.free()
	return true

func _find_kind(kind: StringName) -> int:
	for index in range(_templates.size()):
		if _templates[index].kind == kind:
			return index
	return -1

func _weighted_candidates(transit: bool = false) -> Array[int]:
	var remaining: Array[int] = []
	var weights: Dictionary = {}
	for index in range(_templates.size()):
		var template: Dictionary = _templates[index]
		if template.scene == SHORT_CORRIDOR_SCENE:
			continue
		var is_transit: bool = template.kind in [&"corridor", &"stairs"]
		if template.kind in [&"airlock", &"bridge", &"reactor"] or is_transit != transit:
			continue
		remaining.append(index)
		var weight: float = template.weight
		if transit:
			if template.kind == &"stairs":
				weight *= 2.0
			elif template.doors.size() == 2:
				weight *= 0.3
		weights[index] = weight
	var result: Array[int] = []
	while not remaining.is_empty():
		var total := 0.0
		for index in remaining:
			total += float(weights[index])
		var roll := _rng.randf() * total
		var selected := remaining.size() - 1
		for offset in range(remaining.size()):
			roll -= float(weights[remaining[offset]])
			if roll <= 0.0:
				selected = offset
				break
		result.append(remaining[selected])
		remaining.remove_at(selected)
	return result

func _append_room(template_index: int, placement: Transform3D) -> int:
	var index := _layout.size()
	var template: Dictionary = _templates[template_index]
	var box: AABB = placement * (template.bounds as AABB)
	_layout.append({"template": template_index, "transform": placement, "bounds": box, "transit_run": 0})
	return index

func _attach(template_index: int, source_port: Vector2i, entries: Array[int] = []) -> Vector2i:
	if source_port.x < 0 or source_port.y < 0:
		return Vector2i(-1, -1)
	var template: Dictionary = _templates[template_index]
	var source: Dictionary = _layout[source_port.x]
	var source_socket: Dictionary = _templates[source.template].doors[source_port.y]
	var target: Transform3D = source.transform * source_socket.transform
	var candidates: Array[int] = entries.duplicate()
	if candidates.is_empty():
		for index in range(template.doors.size()):
			candidates.append(index)
	var start := _rng.randi_range(0, candidates.size() - 1)
	for offset in range(candidates.size()):
		var door_index := candidates[(start + offset) % candidates.size()]
		var socket: Dictionary = template.doors[door_index]
		if not (socket.size as Vector2).is_equal_approx(source_socket.size):
			continue
		var placement: Transform3D = target * Transform3D(Basis(Vector3.UP, PI), Vector3.ZERO) * (socket.transform as Transform3D).affine_inverse()
		var box: AABB = placement * (template.bounds as AABB)
		if _overlaps(box):
			continue
		var new_index := _append_room(template_index, placement)
		if template.kind in [&"corridor", &"stairs"]:
			_layout[new_index].transit_run = int(source.transit_run) + 1
		_edges.append({"room_a": source_port.x, "door_a": source_port.y, "room_b": new_index, "door_b": door_index})
		return Vector2i(new_index, door_index)
	return Vector2i(-1, -1)

func _overlaps(box: AABB) -> bool:
	# Socket faces touch exactly; tolerate only floating-point noise, not shared walls.
	var interior := box.grow(-0.005)
	for placed in _layout:
		if interior.intersects(placed.bounds):
			return true
	return false

func _commit_layout() -> void:
	if is_instance_valid(_generated):
		remove_child(_generated)
		_generated.queue_free()
	rooms.clear()
	graph.clear()
	connections.assign(_edges)
	_generated = Node3D.new()
	_generated.name = "GeneratedRooms"
	add_child(_generated)
	for index in range(_layout.size()):
		var planned: Dictionary = _layout[index]
		var room: ShipRoom = _templates[planned.template].scene.instantiate()
		room.name = "%02d_%s" % [index, room.room_kind]
		room.transform = planned.transform
		# Prefabs retain their preview environment/doors for standalone editing.
		_remove_preview_nodes(room)
		_generated.add_child(room)
		rooms.append(room)
		graph.add_point(index, room.position)
	for edge in connections:
		var a := rooms[edge.room_a].get_doors()[edge.door_a]
		var b := rooms[edge.room_b].get_doors()[edge.door_b]
		a.peer = b
		b.peer = a
		graph.connect_points(edge.room_a, edge.room_b)
		if not (_is_transit_room(rooms[edge.room_a]) and _is_transit_room(rooms[edge.room_b])):
			_add_entrance(a, b, rooms[edge.room_b])
	for room in rooms:
		for socket in room.get_doors():
			if socket.peer == null:
				_add_wall(socket, room)

func _remove_preview_nodes(node: Node) -> void:
	for child in node.get_children():
		if child is WorldEnvironment or child.get_script() == DOOR_SCRIPT:
			node.remove_child(child)
			child.free()
		else:
			_remove_preview_nodes(child)

func _is_transit_room(room: ShipRoom) -> bool:
	return room.room_kind in [&"corridor", &"stairs"]

func _add_entrance(a: DoorSocket, b: DoorSocket, room_b: ShipRoom) -> void:
	# Keep the entrance's source on the corridor side regardless of edge order.
	var source := b if _is_transit_room(room_b) else a
	var door := Node3D.new()
	door.name = "Door"
	door.set_script(DOOR_SCRIPT)
	door.set("open_height", source.opening_size.y + 0.4)
	door.set("open_range", 5.0)
	door.set("auto_open", true)
	# Scale only the authored geometry, not the moving root or its travel distance.
	# The asset spans 1.5 x 2 metres and is centered on the socket.
	var visual := DOOR_SCENE.instantiate() as Node3D
	visual.name = "Visual"
	visual.scale = Vector3(source.opening_size.x / 1.5, source.opening_size.y / 2.0, 0.3)
	door.add_child(visual)
	source.add_child(door)

func _add_wall(socket: DoorSocket, room: ShipRoom) -> void:
	# The socket is on the outer face, with +Z inside. Match the shell's
	# ordinary wall thickness/material instead of advertising a sealed door.
	var wall := CSGBox3D.new()
	wall.name = "Wall"
	wall.size = Vector3(socket.opening_size.x, socket.opening_size.y, 0.45)
	wall.position.z = 0.225
	wall.use_collision = true
	for child in room.get_children():
		if child is CSGBox3D:
			wall.material = (child as CSGBox3D).material
			break
	socket.add_child(wall)

