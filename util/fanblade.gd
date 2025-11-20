extends Node3D
@export var speed := 10

func _ready() -> void:
	$AudioStreamPlayer3D.play()
	
# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	self.rotate_y(delta * speed)
