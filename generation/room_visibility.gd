class_name RoomVisibility
extends Node
## Culls rendering only. Room physics, scripts and authored child visibility remain active.

signal current_room_changed(index: int)
signal discovery_changed

const THRESHOLD_MARGIN := 0.2
const SEAM_GRACE := 0.2
const CLIP_EPSILON := 0.000001
const EYE_CLIP_DISTANCE := 0.00001

class Doorway:
	var target: int
	var to_socket: Transform3D
	var half_size: Vector2
	var corners := PackedVector3Array()
	var projected := PackedVector2Array()
	var projection_revision: int = -1
	var windows: Array[PackedVector2Array] = []

class Sightline:
	var room: int
	var window: PackedVector2Array

@export var player_path: NodePath = NodePath("../Player")
@export var ship_path: NodePath = NodePath("../Ship")
## Optional override for fixtures or a non-current camera; otherwise use the viewport's current camera.
@export var camera_path: NodePath
@export var enabled: bool = true:
	set(value):
		enabled = value
		if is_inside_tree() and not _rooms.is_empty():
			if not enabled:
				_restore_rooms()
			refresh()
@export_range(0.01, 1.0, 0.01) var update_interval: float = 0.1

var current_room: int = -1
var discovered_rooms: Dictionary = {}
var active_rooms: Array[int] = []

var _player: Node3D
var _ship: ShipGenerator
var _rooms: Array[ShipRoom] = []
var _authored_visibility: Array[bool] = []
var _bounds: Array[AABB] = []
var _to_room: Array[Transform3D] = []
var _from_room: Array[Transform3D] = []
var _adjacency: Array[PackedInt32Array] = []
var _portals: Array[Array] = []
var _portal_list: Array[Doorway] = []
var _projection_revision: int = 0
var _active_set: Dictionary = {}
var _previous_room: int = -1
var _previous_until: float = 0.0
var _clock: float = 0.0
var _elapsed: float = 0.0
var _last_inside_time: float = -INF
var _last_position := Vector3.ZERO
var _has_last_position: bool = false
var _last_camera: Camera3D
var _last_camera_transform := Transform3D.IDENTITY
var _last_projection := Projection()
var _last_viewport_size := Vector2.ZERO
var _last_ship_transform := Transform3D.IDENTITY


func _ready() -> void:
	# The level resets us only AFTER spawning the player, including initial startup.
	_bind_paths()


func _exit_tree() -> void:
	_restore_rooms()
	_clear_cache()


func reset() -> void:
	_restore_rooms()
	_clear_cache()
	_bind_paths()
	var old_current := current_room
	current_room = -1
	discovered_rooms.clear()
	_clock = 0.0
	_elapsed = 0.0
	_last_inside_time = -INF
	_previous_room = -1
	_previous_until = 0.0
	_has_last_position = false
	_last_camera = null
	if is_instance_valid(_ship):
		# Snapshot the NEW generation, never the nodes detached by the generator.
		var ship_inverse := _ship.global_transform.affine_inverse()
		_rooms.assign(_ship.rooms)
		for index in range(_rooms.size()):
			var room := _rooms[index]
			var placement := ship_inverse * room.global_transform
			_authored_visibility.append(room.visible)
			_bounds.append(room.bounds)
			_from_room.append(placement)
			_to_room.append(placement.affine_inverse())
			_adjacency.append(PackedInt32Array())
			_portals.append([])
			_active_set[index] = true
			active_rooms.append(index)
		# Socket rectangles, including elevated stair exits, are cached in ship
		# space. Door animation never participates: the glass is transparent.
		for connection in _ship.connections:
			var a: int = connection.room_a
			var b: int = connection.room_b
			if a < 0 or b < 0 or a >= _rooms.size() or b >= _rooms.size():
				continue
			var doors_a := _rooms[a].get_doors()
			var doors_b := _rooms[b].get_doors()
			var door_a: int = connection.door_a
			var door_b: int = connection.door_b
			if door_a < 0 or door_b < 0 or door_a >= doors_a.size() or door_b >= doors_b.size():
				continue
			_adjacency[a].append(b)
			_adjacency[b].append(a)
			_cache_portal(a, b, doors_a[door_a], ship_inverse)
			_cache_portal(b, a, doors_b[door_b], ship_inverse)
		for neighbors in _adjacency:
			neighbors.sort()
	if old_current != -1:
		current_room_changed.emit(-1)
	discovery_changed.emit()
	refresh()


func refresh() -> void:
	_elapsed = 0.0
	if _rooms.is_empty() or not is_instance_valid(_player) or not is_instance_valid(_ship):
		return
	var position := _ship.to_local(_player.global_position)
	var old_current := current_room
	var next_room := _find_containing_room(position)
	if next_room != old_current:
		_previous_room = -1
		if old_current >= 0 and next_room >= 0 and _adjacency[old_current].has(next_room):
			_previous_room = old_current
			_previous_until = _clock + SEAM_GRACE
		current_room = next_room
	if _previous_room >= 0 and _clock >= _previous_until:
		_previous_room = -1
	var discovered := false
	if current_room >= 0 and _contains(current_room, position):
		_last_inside_time = _clock
		if not discovered_rooms.has(current_room):
			discovered_rooms[current_room] = true
			discovered = true
	# Outside fallback affects rendering only, never entry or discovery.
	var seed := current_room if current_room >= 0 else _find_nearest_room(position)
	var camera := _get_camera()
	_apply_active(_visible_rooms(camera, seed))
	_last_position = position
	_has_last_position = true
	_last_camera = camera
	_last_ship_transform = _ship.global_transform
	if is_instance_valid(camera):
		_last_camera_transform = camera.get_camera_transform()
		_last_projection = camera.get_camera_projection()
		_last_viewport_size = camera.get_viewport().get_visible_rect().size
	if old_current != current_room:
		current_room_changed.emit(current_room)
	if discovered:
		discovery_changed.emit()


func _physics_process(delta: float) -> void:
	_clock += delta
	_elapsed += delta
	if _rooms.is_empty() or not is_instance_valid(_player) or not is_instance_valid(_ship):
		return
	var position := _ship.to_local(_player.global_position)
	var moved := not _has_last_position or position.distance_squared_to(_last_position) > 0.0001
	var near_boundary := current_room < 0 or not _contains(current_room, position, -THRESHOLD_MARGIN)
	var seam_expired := _previous_room >= 0 and _clock >= _previous_until
	var camera := _get_camera()
	var view_changed := camera != _last_camera or _ship.global_transform != _last_ship_transform
	if is_instance_valid(camera):
		view_changed = view_changed or camera.get_camera_transform() != _last_camera_transform or camera.get_camera_projection() != _last_projection or camera.get_viewport().get_visible_rect().size != _last_viewport_size
	# A stationary player can turn, zoom, change projection or resize the viewport.
	# Those changes refresh at physics cadence, not only after a room crossing.
	if view_changed or _elapsed >= maxf(0.01, update_interval) or seam_expired or (moved and near_boundary):
		refresh()


func _bind_paths() -> void:
	_player = get_node_or_null(player_path) as Node3D
	_ship = get_node_or_null(ship_path) as ShipGenerator


func _get_camera() -> Camera3D:
	if not camera_path.is_empty():
		var explicit := get_node_or_null(camera_path) as Camera3D
		if is_instance_valid(explicit):
			return explicit
	return get_viewport().get_camera_3d()


func _clear_cache() -> void:
	_rooms.clear()
	_authored_visibility.clear()
	_bounds.clear()
	_to_room.clear()
	_from_room.clear()
	_adjacency.clear()
	_portals.clear()
	_portal_list.clear()
	_active_set.clear()
	active_rooms.clear()


func _restore_rooms() -> void:
	for index in range(_rooms.size()):
		if is_instance_valid(_rooms[index]):
			_rooms[index].visible = _authored_visibility[index]


func _cache_portal(source: int, target: int, socket: DoorSocket, ship_inverse: Transform3D) -> void:
	var doorway := Doorway.new()
	doorway.target = target
	var placement := ship_inverse * socket.global_transform
	doorway.to_socket = placement.affine_inverse()
	doorway.half_size = socket.opening_size * 0.5
	var half := doorway.half_size
	for corner in [Vector3(-half.x, -half.y, 0.0), Vector3(half.x, -half.y, 0.0), Vector3(half.x, half.y, 0.0), Vector3(-half.x, half.y, 0.0)]:
		doorway.corners.append(placement * corner)
	_portals[source].append(doorway)
	_portal_list.append(doorway)


func _contains(index: int, position: Vector3, margin: float = 0.0) -> bool:
	# Complete root-local volume, not a floor/deck slice: rotated rooms and the
	# stair prefab's four-metre rise remain one continuous containment region.
	return _bounds[index].grow(margin).has_point(_to_room[index] * position)


func _find_containing_room(position: Vector3) -> int:
	if current_room >= 0:
		if _contains(current_room, position):
			return current_room
		# Prefer actual connected neighbors and require a small penetration before
		# switching, so threshold jitter cannot alternate rooms every physics tick.
		for neighbor in _adjacency[current_room]:
			if _contains(neighbor, position):
				if _contains(current_room, position, THRESHOLD_MARGIN) and not _contains(neighbor, position, -THRESHOLD_MARGIN):
					return current_room
				return neighbor
	for index in range(_rooms.size()):
		if _contains(index, position):
			return index
	if current_room >= 0 and _clock - _last_inside_time <= SEAM_GRACE:
		if _distance_squared(current_room, position) <= THRESHOLD_MARGIN * THRESHOLD_MARGIN:
			return current_room
	return -1


func _distance_squared(index: int, position: Vector3) -> float:
	var local_position := _to_room[index] * position
	var nearest := local_position.clamp(_bounds[index].position, _bounds[index].end)
	return position.distance_squared_to(_from_room[index] * nearest)


func _find_nearest_room(position: Vector3) -> int:
	var nearest := -1
	var distance := INF
	for index in range(_rooms.size()):
		var candidate := _distance_squared(index, position)
		if candidate < distance:
			distance = candidate
			nearest = index
	return nearest


func _visible_rooms(camera: Camera3D, seed: int) -> Dictionary:
	var desired: Dictionary = {}
	if not enabled:
		for index in range(_rooms.size()):
			desired[index] = true
		return desired
	if seed >= 0:
		desired[seed] = true
	if _previous_room >= 0:
		desired[_previous_room] = true
	if not is_instance_valid(camera):
		return desired
	var ship_inverse := _ship.global_transform.affine_inverse()
	var camera_transform := camera.get_camera_transform()
	var eye := ship_inverse * camera_transform.origin
	var root := -1
	if current_room >= 0 and _contains(current_room, eye):
		root = current_room
	else:
		for index in range(_rooms.size()):
			if _contains(index, eye):
				root = index
				break
	if root < 0:
		root = _find_nearest_room(eye)
	if root < 0:
		return desired
	var to_camera := camera_transform.affine_inverse() * _ship.global_transform
	var projection := camera.get_camera_projection()
	var full_window := PackedVector2Array([Vector2(-1.0, -1.0), Vector2(1.0, -1.0), Vector2(1.0, 1.0), Vector2(-1.0, 1.0)])
	_projection_revision += 1
	for doorway in _portal_list:
		doorway.windows.clear()
	var first := Sightline.new()
	first.room = root
	first.window = full_window
	var queue: Array[Sightline] = [first]
	var cursor := 0
	while cursor < queue.size():
		var sightline := queue[cursor]
		cursor += 1
		desired[sightline.room] = true
		for doorway: Doorway in _portals[sightline.room]:
			if doorway.projection_revision != _projection_revision:
				doorway.projected = _project_portal(doorway, eye, to_camera, projection, camera.far, full_window)
				doorway.projection_revision = _projection_revision
			if doorway.projected.size() < 3:
				continue
			var window := _clip_window(doorway.projected, sightline.window)
			if window.size() < 3 or _window_covered(window, doorway.windows):
				continue
			# Coverage belongs to a DIRECTED portal, not to a room. A second path
			# may reveal a different exit. Returning through a cycle only narrows
			# an already-covered window, so it stops without a graph-depth limit.
			for index in range(doorway.windows.size() - 1, -1, -1):
				if _window_contains(window, doorway.windows[index]):
					doorway.windows.remove_at(index)
			doorway.windows.append(window)
			var next := Sightline.new()
			next.room = doorway.target
			next.window = window
			queue.append(next)
	return desired


func _project_portal(doorway: Doorway, eye: Vector3, to_camera: Transform3D, projection: Projection, far_distance: float, full_window: PackedVector2Array) -> PackedVector2Array:
	var local_eye := doorway.to_socket * eye
	# Socket +Z points into the source room. Do not walk back through a portal
	# behind the eye; a small seam allowance covers threshold hysteresis.
	if local_eye.z < -THRESHOLD_MARGIN:
		return PackedVector2Array()
	if absf(local_eye.z) <= THRESHOLD_MARGIN and absf(local_eye.x) <= doorway.half_size.x + THRESHOLD_MARGIN and absf(local_eye.y) <= doorway.half_size.y + THRESHOLD_MARGIN:
		# At the doorway plane projection collapses, although the view through it
		# is open. Treat just this touching aperture conservatively as full view.
		return full_window
	var polygon := PackedVector3Array()
	for corner in doorway.corners:
		polygon.append(to_camera * corner)
	# Use the eye plane, NOT the render near plane: a doorway between the eye
	# and camera.near still exposes the rooms beyond it. Clipping before divide
	# also handles apertures crossing the eye plane without inverted polygons.
	polygon = _clip_depth(polygon, -EYE_CLIP_DISTANCE, true)
	polygon = _clip_depth(polygon, -far_distance, false)
	if polygon.size() < 3:
		return PackedVector2Array()
	var projected := PackedVector2Array()
	for point in polygon:
		var clip := projection * Vector4(point.x, point.y, point.z, 1.0)
		if absf(clip.w) <= 0.0000001:
			return full_window
		projected.append(Vector2(clip.x, clip.y) / clip.w)
	var area := 0.0
	for index in range(projected.size()):
		area += projected[index].cross(projected[(index + 1) % projected.size()])
	if area < 0.0:
		projected.reverse()
	elif area == 0.0:
		return PackedVector2Array()
	return _clip_window(projected, full_window)


func _clip_depth(polygon: PackedVector3Array, depth: float, keep_less: bool) -> PackedVector3Array:
	var result := PackedVector3Array()
	if polygon.is_empty():
		return result
	var previous := polygon[polygon.size() - 1]
	var previous_inside := previous.z <= depth if keep_less else previous.z >= depth
	for point in polygon:
		var inside := point.z <= depth if keep_less else point.z >= depth
		if inside != previous_inside:
			result.append(previous.lerp(point, (depth - previous.z) / (point.z - previous.z)))
		if inside:
			result.append(point)
		previous = point
		previous_inside = inside
	return result


func _clip_window(polygon: PackedVector2Array, aperture: PackedVector2Array) -> PackedVector2Array:
	var result := polygon
	for index in range(aperture.size()):
		if result.size() < 3:
			return PackedVector2Array()
		var start := aperture[index]
		var edge := aperture[(index + 1) % aperture.size()] - start
		var clipped := PackedVector2Array()
		var previous := result[result.size() - 1]
		var previous_distance := edge.cross(previous - start)
		for point in result:
			var distance := edge.cross(point - start)
			var inside := distance >= -CLIP_EPSILON
			var previous_inside := previous_distance >= -CLIP_EPSILON
			if inside != previous_inside:
				var weight := clampf(previous_distance / (previous_distance - distance), 0.0, 1.0)
				clipped.append(previous.lerp(point, weight))
			if inside:
				clipped.append(point)
			previous = point
			previous_distance = distance
		result = clipped
	# A line/point contact is not an aperture. In particular, never cache a
	# degenerate window whose zero-length edges could appear to cover all paths.
	var area := 0.0
	for index in range(result.size()):
		area += result[index].cross(result[(index + 1) % result.size()])
	if area == 0.0:
		return PackedVector2Array()
	return result


func _window_contains(outer: PackedVector2Array, inner: PackedVector2Array) -> bool:
	for index in range(outer.size()):
		var start := outer[index]
		var edge := outer[(index + 1) % outer.size()] - start
		for point in inner:
			if edge.cross(point - start) < -CLIP_EPSILON:
				return false
	return true


func _window_covered(window: PackedVector2Array, previous: Array[PackedVector2Array]) -> bool:
	for outer in previous:
		if _window_contains(outer, window):
			return true
	return false


func _apply_active(desired: Dictionary) -> void:
	for index in _active_set:
		if not desired.has(index):
			_set_room_active(index, false)
	for index in desired:
		if not _active_set.has(index):
			_set_room_active(index, true)
	_active_set = desired
	active_rooms.clear()
	for index in desired:
		active_rooms.append(index)
	active_rooms.sort()


func _set_room_active(index: int, active: bool) -> void:
	if is_instance_valid(_rooms[index]):
		# Inherited Node3D visibility removes descendant meshes AND Light3D render
		# instances (including shadows). Never change energy, shadow flags, child
		# visibility, processing or collision: F7 and authored hidden labels survive.
		_rooms[index].visible = active and _authored_visibility[index]
