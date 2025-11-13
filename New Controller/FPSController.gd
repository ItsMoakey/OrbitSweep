extends CharacterBody3D

@export var look_sensitivity : float = 0.006
@export var jump_velocity := 6.0
@export var auto_bhop := true
@export var walk_speed := 7.0
@export var sprint_speed := 8.5

@onready var light = $Head/Camera3D/SpotLight3D

var wish_dir := Vector3.ZERO
var LightBool := false

func get_move_speed() -> float:
	return sprint_speed if Input.is_action_pressed("Shift") else walk_speed

# Called when the node enters the scene tree for the first time.
func _ready():
	for child in %deco.find_children("*","VisualInstance3D"): #Hiding Visuals
		child.set_layer_mask_value(1, false)
		child.set_layer_mask_value(2, true)

func _unhandled_input(event): #LOOK!
	if event is InputEventMouseButton:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	elif event.is_action_pressed("ui_cancel"):
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	
	if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		if event is InputEventMouseMotion:
			rotate_y(-event.relative.x * look_sensitivity)
			%Camera3D.rotate_x(-event.relative.y * look_sensitivity)
			%Camera3D.rotation.x = clamp(%Camera3D.rotation.x,deg_to_rad(-89), deg_to_rad(89))

	if Input.is_action_just_pressed("F"):
		_handle_flashlight()
func _process(delta):
	pass

func _handle_air_physics(delta) -> void:
	self.velocity.y -= ProjectSettings.get_setting("physics/3d/default_gravity") * delta

func _handle_ground_physics(delta) -> void:
	self.velocity.x = wish_dir.x * get_move_speed()
	self.velocity.z = wish_dir.z * get_move_speed()

func _physics_process(delta):
	var input_dir = Input.get_vector("D","A","S","W").normalized()
	#input and direction
	wish_dir = self.global_transform.basis * Vector3(-input_dir.x,0., -input_dir.y)
	print(wish_dir)

	if is_on_floor():
		if Input.is_action_just_pressed("Space"):
			self.velocity.y  = jump_velocity
		_handle_ground_physics(delta)
	else:
		_handle_air_physics(delta)

	move_and_slide()
func _handle_flashlight():
	if !LightBool:
		light.light_energy = 5
		LightBool = true
	else:
		light.light_energy = 0
		LightBool = false
