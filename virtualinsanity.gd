extends CSGBox3D

var start_position: Vector3
var phase: int = -1
var elapsed: float = 0.0
var move_distance_left: float = 4.0
var move_distance_forward: float = 4.0
var delay_duration: float = 5.0
var left_duration: float = 2.0
var forward_duration: float = 3.0


func _ready() -> void:
	start_position = position


func _process(delta: float) -> void:
	if phase == -1:
		elapsed += delta
		if elapsed >= delay_duration:
			elapsed = 0.0
			phase = 0
	elif phase == 0:
		elapsed += delta
		var t: float = clamp(elapsed / left_duration, 0.0, 1.0)
		position = start_position + Vector3(-move_distance_left * t, 0.0, 0.0)
		if t >= 1.0:
			elapsed = 0.0
			phase = 1
	elif phase == 1:
		elapsed += delta
		var t: float = clamp(elapsed / forward_duration, 0.0, 1.0)
		position = start_position + Vector3(-move_distance_left, 0.0, move_distance_forward * t)
		if t >= 1.0:
			phase = 2
