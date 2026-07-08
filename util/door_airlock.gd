extends Node3D

@export var open_height: float = 1.5
@export var open_range: float = 4.0
@export var lerp_speed: float = 5.0

var _closed_position: Vector3
var _open_position: Vector3
var _target_position: Vector3
var _player: CharacterBody3D

func _ready() -> void:
	_closed_position = global_transform.origin
	_open_position = _closed_position + Vector3(0, open_height, 0)
	_target_position = _closed_position
	_player = _find_player()

func _process(delta: float) -> void:
	if _player:
		var distance = _closed_position.distance_to(_player.global_position)
		_target_position = _open_position if distance <= open_range else _closed_position

	global_position = global_position.lerp(_target_position, lerp_speed * delta)

func _find_player() -> CharacterBody3D:
	for node in get_tree().get_root().get_children():
		if node is CharacterBody3D:
			return node
		var found = _find_player_recursive(node)
		if found:
			return found
	return null

func _find_player_recursive(node: Node) -> CharacterBody3D:
	for child in node.get_children():
		if child is CharacterBody3D:
			return child
		var found = _find_player_recursive(child)
		if found:
			return found
	return null
