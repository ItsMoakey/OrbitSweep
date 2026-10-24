class_name Button3D
extends StaticBody3D
## Pressable wall/console button. Look at it and hit the interact key (Grab, G) and it fires.
##
## The player controller raycasts forward and calls `interact(player)` on whatever it hits,
## so anything with that method works the same way; this is just the button version.
##
## What it activates:
##  - `pressed(presser)` signal, fires every press. Connect it in the editor for anything custom.
##  - `toggled(is_on)` signal, only in toggle mode.
##  - `targets`: nodes that get `target_method` called on them (default "activate").
##    In toggle mode, a target that has `set_active(bool)` gets that instead, so lights/doors
##    can follow the button state rather than flipping on every press.
##
## Faces local -Z like everything else, the cap pushes in along +Z.

signal pressed(presser: Node)
signal toggled(is_on: bool)

@export var targets: Array[Node] = []
@export var target_method := "activate"
@export var toggle_mode := false
## Seconds before it can be pressed again.
@export var cooldown := 0.3
@export var enabled := true
@export_group("Look")
@export var press_depth := 0.04
@export var press_time := 0.08
@export var off_color := Color(0.8, 0.1, 0.1)
@export var on_color := Color(0.1, 0.9, 0.2)
@export var emission_energy := 2.0
@export_group("Sound")
## Optional. Played on each press if set.
@export var press_sound: AudioStream

@onready var _cap: Node3D = $Cap
@onready var _sfx: AudioStreamPlayer3D = $PressSound

var is_on := false
var _cooldown_left := 0.0
var _cap_rest := Vector3.ZERO
var _mat: StandardMaterial3D

func _ready() -> void:
	_cap_rest = _cap.position
	_sfx.stream = press_sound
	var mesh := _cap as CSGShape3D
	if mesh:
		_mat = StandardMaterial3D.new()
		_mat.emission_enabled = true
		mesh.material = _mat
	_refresh_look()

func _process(delta: float) -> void:
	if _cooldown_left > 0.0:
		_cooldown_left = maxf(0.0, _cooldown_left - delta)

# Called by the player controller.
func interact(presser: Node = null) -> bool:
	if not enabled or _cooldown_left > 0.0:
		return false
	_cooldown_left = cooldown
	if toggle_mode:
		is_on = not is_on
	_animate_press()
	if press_sound:
		_sfx.play()
	_refresh_look()
	pressed.emit(presser)
	if toggle_mode:
		toggled.emit(is_on)
	_fire_targets()
	return true

func _fire_targets() -> void:
	for t in targets:
		if t == null or not is_instance_valid(t):
			continue
		if toggle_mode and t.has_method("set_active"):
			t.call("set_active", is_on)
		elif t.has_method(target_method):
			t.call(target_method)
		else:
			push_warning("%s: target %s has no method '%s'" % [name, t.name, target_method])

func _animate_press() -> void:
	var tw := create_tween()
	tw.tween_property(_cap, "position", _cap_rest + Vector3(0, 0, press_depth), press_time)
	# toggle buttons stay in while on, momentary ones pop back out
	var end := _cap_rest + (Vector3(0, 0, press_depth) if (toggle_mode and is_on) else Vector3.ZERO)
	tw.tween_property(_cap, "position", end, press_time)

func _refresh_look() -> void:
	if _mat == null:
		return
	var c := on_color if (toggle_mode and is_on) else off_color
	_mat.albedo_color = c
	_mat.emission = c
	_mat.emission_energy_multiplier = emission_energy
