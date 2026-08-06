extends CSGBox3D

@export var damage_amount: int = 10
@export var damage_interval: float = 0.5

var _contact_timers := {}

func _ready() -> void:
	_setup_damage_area()

func _physics_process(delta: float) -> void:
	for body in _contact_timers.keys():
		if not body or not is_instance_valid(body):
			_contact_timers.erase(body)
			continue

		_contact_timers[body] = max(0.0, _contact_timers[body] - delta)
		if _contact_timers[body] == 0.0 and body.has_method("_health"):
			body.call("_health", -damage_amount)
			_contact_timers[body] = damage_interval

func _setup_damage_area() -> void:
	var area: Area3D
	if has_node("DamageArea"):
		area = $DamageArea
	else:
		area = Area3D.new()
		area.name = "DamageArea"
		area.monitoring = true
		area.monitorable = true
		var shape = CollisionShape3D.new()
		var box = BoxShape3D.new()
		box.extents = size / 2.0
		shape.shape = box
		area.add_child(shape)
		add_child(area)

	area.body_entered.connect(Callable(self, "_on_body_entered"))
	area.body_exited.connect(Callable(self, "_on_body_exited"))

func _on_body_entered(body: Node) -> void:
	if body and body.has_method("_health"):
		_contact_timers[body] = 0.0

func _on_body_exited(body: Node) -> void:
	if body in _contact_timers:
		_contact_timers.erase(body)
