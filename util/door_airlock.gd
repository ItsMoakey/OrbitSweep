extends Node3D

@export var open_height: float = 1.5
@export var open_range: float = 4.0
@export var lerp_speed: float = 5.0
@export var auto_open := true   # turn off for button-only doors

var _closed_position: Vector3
var _open_position: Vector3
var _target_position: Vector3
var _player: CharacterBody3D
var _forced_open := false

func _ready() -> void:
	_closed_position = global_transform.origin
	_open_position = _closed_position + Vector3(0, open_height, 0)
	_target_position = _closed_position
	_player = _find_player()

# Button3D calls one of these on its targets
func activate() -> void:           # plain button: flips the door each press
	_forced_open = not _forced_open

func set_active(on: bool) -> void: # toggle_mode button: door follows the button state
	_forced_open = on

func _process(delta: float) -> void:
	var near := false
	if auto_open and _player:
		near = _closed_position.distance_to(_player.global_position) <= open_range
	_target_position = _open_position if (near or _forced_open) else _closed_position

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