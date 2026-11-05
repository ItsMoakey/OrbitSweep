@tool
class_name DoorSocket
extends Marker3D
## Place at the outer wall face; local -Z points out of the room.

@export var opening_size: Vector2 = Vector2(5.4, 3.6)

var peer: DoorSocket
