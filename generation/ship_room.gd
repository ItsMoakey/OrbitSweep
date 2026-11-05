@tool
class_name ShipRoom
extends Node3D
## Bounds include the complete shell, in this node's local coordinates.

@export var room_kind: StringName = &"room"
@export var bounds: AABB = AABB(Vector3(-5, -2.25, -5), Vector3(10, 4.5, 10))
@export_range(0.01, 20.0) var selection_weight: float = 1.0

func get_doors() -> Array[DoorSocket]:
	var result: Array[DoorSocket] = []
	var container := get_node_or_null("Doors")
	if container:
		for child in container.get_children():
			if child is DoorSocket:
				result.append(child)
	return result
