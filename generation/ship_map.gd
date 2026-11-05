class_name ShipMap
extends Control
## A ship-local floorplan. Geometry is cached by value; exploration is owned by RoomVisibility.

const INK := Color(0.45, 0.65, 1.0)
const CURRENT := Color(0.3, 1.0, 0.45)
const BRIDGE := Color(0.3, 0.9, 1.0)
const REACTOR := Color(1.0, 0.45, 0.25)
const STAIRS := Color(1.0, 0.85, 0.3)
const DECK_TOLERANCE := 0.15

class Floorplan extends Control:
	var map: ShipMap

	func _draw() -> void:
		map._draw_floorplan(self)

var selected_deck: float = 0.0
var discovered_decks: Array[float] = []
var player_deck: float = 0.0

var _ship: ShipGenerator
var _player: Node3D
var _visibility: RoomVisibility
var _rooms: Array[Dictionary] = []
var _connections: Array[Dictionary] = []
var _canvas: Floorplan
var _font: Font
var _manual_deck := false
var _follow_player := false
var _zoom := 1.0
var _fit_scale := 1.0
var _center := Vector2.ZERO
var _elapsed := 0.0
var _label_rects: Array[Rect2] = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = ThemeDB.fallback_font
	_canvas = Floorplan.new()
	_canvas.map = self
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.clip_contents = true
	add_child(_canvas)
	resized.connect(_resize_canvas)
	_resize_canvas()
	set_process(false)


func setup(ship: ShipGenerator, player: Node3D, visibility: RoomVisibility) -> void:
	_ship = ship
	_player = player
	_visibility = visibility
	_visibility.discovery_changed.connect(_on_discovery_changed)
	_visibility.current_room_changed.connect(_on_current_room_changed)


func refresh() -> void:
	# Called only after a successful generation and the player's spawn/reset.
	_rooms.clear()
	_connections.clear()
	for room in _ship.rooms:
		_rooms.append(_room_geometry(room))
	for edge in _ship.connections:
		var a: int = edge.room_a
		var b: int = edge.room_b
		var door_a: Dictionary = _rooms[a].sockets[edge.door_a]
		var door_b: Dictionary = _rooms[b].sockets[edge.door_b]
		_connections.append({"a": a, "b": b, "door_a": door_a, "door_b": door_b})
	_manual_deck = false
	_follow_player = false
	_zoom = 1.0
	_update_decks()
	_fit_explored()
	_redraw()


func toggle() -> void:
	visible = not visible
	set_process(visible)
	if visible:
		_visibility.refresh()
		_manual_deck = false
		_update_decks()
		_fit_explored()
		_redraw()


func change_deck(direction: int) -> void:
	if discovered_decks.is_empty():
		return
	var index := discovered_decks.find(selected_deck)
	index = clampi(index + direction, 0, discovered_decks.size() - 1)
	selected_deck = discovered_decks[index]
	_manual_deck = true
	_follow_player = false
	_fit_explored()
	_redraw()


func change_zoom(direction: int) -> void:
	_zoom = clampf(_zoom * pow(1.35, direction), 0.5, 12.0)
	_redraw()


func fit_explored() -> void:
	_zoom = 1.0
	_follow_player = false
	_fit_explored()
	_redraw()


func center_player() -> void:
	_manual_deck = false
	_follow_player = true
	_update_decks()
	_center = _flat(_ship.to_local(_player.global_position))
	_redraw()


func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed < 0.05:
		return
	_elapsed = 0.0
	_update_decks()
	if _follow_player:
		_center = _flat(_ship.to_local(_player.global_position))
	_redraw()


func _on_discovery_changed() -> void:
	_update_decks()
	if not _follow_player:
		_fit_explored()
	_redraw()


func _on_current_room_changed(_index: int) -> void:
	_update_decks()
	_redraw()


func _resize_canvas() -> void:
	_canvas.position = Vector2(16.0, 64.0)
	_canvas.size = Vector2(maxf(1.0, size.x - 32.0), maxf(1.0, size.y - 104.0))
	_fit_explored()
	_redraw()


func _redraw() -> void:
	queue_redraw()
	if is_instance_valid(_canvas):
		_canvas.queue_redraw()


func _room_geometry(room: ShipRoom) -> Dictionary:
	var relative := _ship.global_transform.affine_inverse() * room.global_transform
	var sockets: Array[Dictionary] = []
	var decks: Array[float] = []
	var local_doors: Array[Vector3] = []
	var widths: Array[float] = []
	for socket in room.get_doors():
		var socket_transform := _ship.global_transform.affine_inverse() * socket.global_transform
		var point := socket_transform.origin
		var height := snappedf(point.y, 0.05)
		if not decks.has(height):
			decks.append(height)
		sockets.append({"position": _flat(point), "inside": _flat(point + socket_transform.basis.z.normalized() * 1.2), "height": height})
		local_doors.append(room.to_local(socket.global_position))
		widths.append(socket.opening_size.x)
	decks.sort()
	var polygons: Array[PackedVector2Array] = []
	if room.room_kind == &"corridor" and not local_doors.is_empty():
		# Union narrow socket arms, so L/T/X passages do not become solid square rooms.
		var half_width := widths[0] * 0.5
		var outlines: Array[PackedVector2Array] = [PackedVector2Array([
			Vector2(-half_width, -half_width), Vector2(half_width, -half_width),
			Vector2(half_width, half_width), Vector2(-half_width, half_width)])]
		for index in range(local_doors.size()):
			var end := _flat(local_doors[index])
			if end.length_squared() < 0.01:
				continue
			var direction := end.normalized()
			var side := Vector2(-direction.y, direction.x) * widths[index] * 0.5
			var arm := PackedVector2Array([side, end + side, end - side, -side])
			var merged := Geometry2D.merge_polygons(outlines[0], arm)
			if merged.size() == 1:
				outlines[0] = merged[0]
			else:
				outlines.append(arm)
		for outline in outlines:
			var transformed := PackedVector2Array()
			for point in outline:
				transformed.append(_flat(relative * Vector3(point.x, 0.0, point.y)))
			polygons.append(transformed)
	else:
		var minimum := room.bounds.position
		var maximum := room.bounds.end
		polygons.append(PackedVector2Array([
			_flat(relative * Vector3(minimum.x, 0.0, minimum.z)),
			_flat(relative * Vector3(maximum.x, 0.0, minimum.z)),
			_flat(relative * Vector3(maximum.x, 0.0, maximum.z)),
			_flat(relative * Vector3(minimum.x, 0.0, maximum.z))]))
	return {"kind": room.room_kind, "center": _flat(relative.origin), "polygons": polygons, "sockets": sockets, "decks": decks}


func _update_decks() -> void:
	if not is_instance_valid(_visibility) or not is_instance_valid(_player):
		return
	discovered_decks.clear()
	for key in _visibility.discovered_rooms:
		var index := int(key)
		if not _is_discovered(index):
			continue
		for height in _rooms[index].decks:
			if not discovered_decks.has(height):
				discovered_decks.append(height)
	discovered_decks.sort()
	var local_player := _ship.to_local(_player.global_position)
	# The body origin is near socket height on level floors. On stairs, choose
	# the nearest of that room's real landings, not a bounds-derived fake floor.
	var candidates: Array[float] = discovered_decks
	var current := _visibility.current_room
	if _is_discovered(current):
		candidates = _rooms[current].decks
	var closest := INF
	for height in candidates:
		var distance := absf(height - local_player.y)
		if distance < closest:
			closest = distance
			player_deck = height
	if not _manual_deck or not discovered_decks.has(selected_deck):
		if not is_equal_approx(selected_deck, player_deck):
			selected_deck = player_deck
			if not _follow_player:
				_fit_explored()


func _is_discovered(index: int) -> bool:
	return index >= 0 and index < _rooms.size() and bool(_visibility.discovered_rooms.get(index, false))


func _on_deck(room: Dictionary) -> bool:
	for height in room.decks:
		if absf(height - selected_deck) < DECK_TOLERANCE:
			return true
	return false


func _fit_explored() -> void:
	if not is_instance_valid(_canvas) or not is_instance_valid(_visibility):
		return
	var bounds := Rect2()
	var found := false
	for index in range(_rooms.size()):
		if not _is_discovered(index) or not _on_deck(_rooms[index]):
			continue
		for polygon in _rooms[index].polygons:
			for point in polygon:
				if not found:
					bounds = Rect2(point, Vector2.ZERO)
					found = true
				else:
					bounds = bounds.expand(point)
	if not found:
		return
	bounds = bounds.grow(7.0)
	_center = bounds.get_center()
	_fit_scale = minf(_canvas.size.x / maxf(bounds.size.x, 1.0), _canvas.size.y / maxf(bounds.size.y, 1.0))


func _screen(point: Vector2) -> Vector2:
	return (point - _center) * _fit_scale * _zoom + _canvas.size * 0.5


func _flat(point: Vector3) -> Vector2:
	return Vector2(point.x, point.z)


func _room_color(index: int) -> Color:
	if index == _visibility.current_room:
		return CURRENT
	match _rooms[index].kind:
		&"bridge":
			return BRIDGE
		&"reactor":
			return REACTOR
		&"stairs":
			return STAIRS
	return INK


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.08, 0.08, 0.08))
	if not is_instance_valid(_visibility):
		return
	draw_string(_font, Vector2(16.0, 24.0), "Map - floor %+.0fm" % selected_deck, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 16, Color.WHITE)
	if absf(player_deck - selected_deck) > DECK_TOLERANCE:
		draw_string(_font, Vector2(16.0, 46.0), "Player is on %+.0fm (Home)" % player_deck, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 12, Color.WHITE)
	draw_string(_font, Vector2(16.0, size.y - 14.0), "Tab close | +/- zoom | PgUp/PgDn floors | Home player | End fit", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 12, Color.WHITE)


func _draw_floorplan(canvas: Control) -> void:
	if not is_instance_valid(_visibility):
		return
	for index in range(_rooms.size()):
		if not _is_discovered(index) or not _on_deck(_rooms[index]):
			continue
		var color := _room_color(index)
		for polygon in _rooms[index].polygons:
			var screen_polygon := PackedVector2Array()
			for point in polygon:
				screen_polygon.append(_screen(point))
			canvas.draw_colored_polygon(screen_polygon, Color(color, 0.25))
			screen_polygon.append(screen_polygon[0])
			canvas.draw_polyline(screen_polygon, color, 1.0)
		if _rooms[index].kind == &"stairs":
			_draw_stairs(canvas, _rooms[index])
	for edge in _connections:
		if not _is_discovered(edge.a) or not _is_discovered(edge.b):
			continue
		var a: Dictionary = edge.door_a
		var b: Dictionary = edge.door_b
		if absf(a.height - selected_deck) > DECK_TOLERANCE:
			continue
		canvas.draw_polyline(PackedVector2Array([_screen(a.inside), _screen(a.position), _screen(b.position), _screen(b.inside)]), INK, 2.0)
	_label_rects.clear()
	# Important rooms get first choice of label space; generic rooms never reveal destinations.
	for important in [true, false]:
		for index in range(_rooms.size()):
			if not _is_discovered(index) or not _on_deck(_rooms[index]):
				continue
			var kind: StringName = _rooms[index].kind
			var special := kind in [&"bridge", &"reactor", &"stairs"] or index == _visibility.current_room
			if special != important or (not special and _fit_scale * _zoom < 2.0):
				continue
			var text := String(kind).replace("_", " ")
			if kind == &"corridor":
				continue
			_draw_label(canvas, _screen(_rooms[index].center), text, _room_color(index), special)
	_draw_player(canvas)


func _draw_stairs(canvas: Control, room: Dictionary) -> void:
	if room.sockets.size() < 2:
		return
	var start := _screen(room.sockets[0].position)
	var end := _screen(room.sockets[-1].position)
	canvas.draw_line(start, end, STAIRS, 2.0)
	var destination: float = room.decks[-1] if selected_deck < room.decks[-1] - DECK_TOLERANCE else room.decks[0]
	var text := "%s %+.0fm" % ["up" if destination > selected_deck else "down", destination]
	var anchor := _screen(room.center) + Vector2(0.0, 16.0)
	canvas.draw_string(_font, anchor, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 11, STAIRS)


func _draw_label(canvas: Control, anchor: Vector2, text: String, color: Color, important: bool) -> void:
	var font_size := 13 if important else 11
	var extent := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	var rect := Rect2(anchor - Vector2(extent.x * 0.5 + 4.0, extent.y + 1.0), extent + Vector2(8.0, 4.0))
	if not Rect2(Vector2.ZERO, canvas.size).encloses(rect):
		return
	for previous in _label_rects:
		if previous.intersects(rect):
			return
	_label_rects.append(rect)
	canvas.draw_string(_font, anchor - Vector2(extent.x * 0.5, 4.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, color)


func _draw_player(canvas: Control) -> void:
	if absf(player_deck - selected_deck) > DECK_TOLERANCE:
		return
	var point := _screen(_flat(_ship.to_local(_player.global_position)))
	var forward := _ship.global_transform.basis.inverse() * (-_player.global_transform.basis.z)
	var heading := _flat(forward).normalized()
	if heading.length_squared() < 0.01:
		heading = Vector2.UP
	canvas.draw_circle(point, 4.0, Color.WHITE)
	canvas.draw_line(point, point + heading * 15.0, Color.WHITE, 2.0)
