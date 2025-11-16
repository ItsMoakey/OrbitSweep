extends CharacterBody3D

@export var look_sensitivity : float = 0.006
@export var controller_look_sensitivity : float = 0.05
@export var jump_velocity := 6.0
@export var auto_bhop := true


const HEADBOB_MOVE_AMOUNT = 0.06
const HEADBOB_FREQUENCY = 2.4
var headbob_time := 0.0

@export var walk_speed := 7.0
@export var sprint_speed := 8.5
@export var ground_accel := 14.0
@export var ground_decel := 10.0
@export var ground_friction := 6.0

@export var air_cap := 0.05
@export var air_accel := 800.0
@export var air_move_speed := 500.0

@onready var light = $Head/Camera3D/SpotLight3D

var wish_dir := Vector3.ZERO
var cam_aligned_wish_dir := Vector3
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
		
func _headbob_effect(delta):
	headbob_time -= delta * self.velocity.length()
	%Camera3D.transform.origin = Vector3(
		cos(headbob_time * HEADBOB_FREQUENCY * 0.5) * HEADBOB_MOVE_AMOUNT,
		sin(headbob_time * HEADBOB_FREQUENCY) * HEADBOB_MOVE_AMOUNT,
		0
	)
	
var _cur_controller_look = Vector2()
func _handle_controller_look_input(delta):
	var target_look = Input.get_vector("look_left","look_right","look_up","look_down").normalized()
	
	if target_look.length() < _cur_controller_look.length():
		_cur_controller_look = target_look
	else:
		_cur_controller_look = _cur_controller_look.lerp(target_look,5.0 * delta)
	
	rotate_y(-_cur_controller_look.x * controller_look_sensitivity)
	%Camera3D.rotate_x(-_cur_controller_look.y * controller_look_sensitivity)
	%Camera3D.rotation.x = clamp(%Camera3D.rotation.x,deg_to_rad(-89), deg_to_rad(89))
	
func _process(delta):
	_handle_controller_look_input(delta)

func _handle_air_physics(delta) -> void:
	self.velocity.y -= ProjectSettings.get_setting("physics/3d/default_gravity") * delta
	
	var cur_speed_in_wish_dir = self.velocity.dot(wish_dir)
	var capped_speed = min((air_move_speed * wish_dir).length(),air_cap)
	var add_speed_till_cap = capped_speed - cur_speed_in_wish_dir
	if add_speed_till_cap > 0:
		var accel_speed = air_accel * air_move_speed * delta
		accel_speed = min(accel_speed, add_speed_till_cap)
		self.velocity += accel_speed * wish_dir

func _handle_ground_physics(delta) -> void:
	var cur_speed_in_wish_dir = self.velocity.dot(wish_dir)
	var add_speed_till_cap = get_move_speed() - cur_speed_in_wish_dir
	if add_speed_till_cap > 0:
		var accel_speed = ground_accel * get_move_speed() * delta
		accel_speed = min(accel_speed, add_speed_till_cap)
		self.velocity += accel_speed * wish_dir
		
		var control = max(self.velocity.length(), ground_decel)
		var drop = control * ground_friction * delta
		var new_speed = max(self.velocity.length() - drop , 0.0)
		if self.velocity.length() > 0:
			new_speed /= self.velocity.length()
		self.velocity *= new_speed
			
	_headbob_effect(delta)

func _physics_process(delta):
	var input_dir = Input.get_vector("D","A","S","W").normalized()
	#input and direction
	wish_dir = self.global_transform.basis * Vector3(-input_dir.x,0., -input_dir.y)

	if is_on_floor():
		if Input.is_action_just_pressed("Space") or (auto_bhop and Input.is_action_pressed("Space")):
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
