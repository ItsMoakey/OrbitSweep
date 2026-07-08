extends CharacterBody3D

@export var look_sensitivity : float = 0.006
@export var controller_look_sensitivity : float = 0.05
@export var jump_velocity := 6.0
@export var auto_bhop := true

const HEADBOB_MOVE_AMOUNT = 0.06
const HEADBOB_FREQUENCY = 2.4
var headbob_time := 0.0
var headtransform = Vector3.ZERO

@export var walk_speed := 7.0
@export var sprint_speed := 10.0
@export var ground_accel := 14.0
@export var ground_decel := 10.0
@export var ground_friction := 6.0

@export var air_cap := 0.05
@export var air_accel := 800.0
@export var air_move_speed := 500.0

@onready var light = $HeadOriginalPos/Head/CameraSmooth/Camera3D/SpotLight3D
@onready var walksound = $HeadOriginalPos/Head/CameraSmooth/Camera3D/WalkingSound
@onready var jumpingsound = $HeadOriginalPos/Head/CameraSmooth/Camera3D/JumpingSound
@onready var flashlightsound = $HeadOriginalPos/Head/CameraSmooth/Camera3D/FlashlightSound
@export var lightenergy := 1.0

var wish_dir := Vector3.ZERO
var cam_aligned_wish_dir := Vector3.ZERO
var LightBool := false

const CROUCH_TRANSLATE = 0.7
const CROUCH_JUMP_ADD = CROUCH_TRANSLATE * 0.9
var is_crouched := false

var noclip_speed_mult := 3.0
var noclip := false

const MAX_STEP_HEIGHT = 0.5
var _snapped_to_stairs_last_frame := false
var _last_frame_was_on_floor = -INF


func get_move_speed() -> float:
	if is_crouched:
		return walk_speed * 0.8
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
	
	if event is InputEventMouseButton and event.is_pressed():
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			noclip_speed_mult = min(100.0, noclip_speed_mult * 1.1)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			noclip_speed_mult = max(0.1, noclip_speed_mult * 0.9)

	if Input.is_action_just_pressed("F"):
		_handle_flashlight()
		
func _headbob_effect(delta):
	var centerscreen = Vector3.ZERO
	headbob_time -= delta * self.velocity.length()
	if wish_dir != Vector3.ZERO:
		%Camera3D.transform.origin = %Camera3D.transform.origin.lerp(headtransform, 10.0 * delta)
		headtransform = Vector3(
		cos(headbob_time * HEADBOB_FREQUENCY * 0.5) * HEADBOB_MOVE_AMOUNT,
		sin(headbob_time * HEADBOB_FREQUENCY) * HEADBOB_MOVE_AMOUNT,
		0)
	else:
		%Camera3D.transform.origin = %Camera3D.transform.origin.lerp(centerscreen,10.0 * delta)
		
	
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
	
var _saved_camera_global_pos = null
func _save_camera_pos_for_smoothing():
	if _saved_camera_global_pos == null:
		_saved_camera_global_pos = %CameraSmooth.global_position
		
func _slide_camera_smooth_back_to_origin(delta):
	if _saved_camera_global_pos == null: return
	%CameraSmooth.global_position.y = _saved_camera_global_pos.y
	%CameraSmooth.position.y = clampf(%CameraSmooth.position.y, -0.7, 0.7)
	var move_amount = max(self.velocity.length() * delta, walk_speed/2 * delta)
	%CameraSmooth.position.y = move_toward(%CameraSmooth.position.y, 0.0, move_amount)
	_saved_camera_global_pos = %CameraSmooth.global_position
	if %CameraSmooth.position.y == 0:
		_saved_camera_global_pos = null
	
func _snap_down_to_stairs_check() -> void:
	var did_snap := false
	%StairsBelowRayCast3D.force_raycast_update()
	var floor_below : bool = %StairsBelowRayCast3D.is_colliding() and not is_surface_too_steep(%StairsBelowRayCast3D.get_collision_normal())
	var was_on_floor_last_frame = Engine.get_physics_frames() == _last_frame_was_on_floor
	if not is_on_floor() and velocity.y <= 0 and (was_on_floor_last_frame or _snapped_to_stairs_last_frame) and floor_below:
		var body_test_result = KinematicCollision3D.new()
		if self.test_move(self.global_transform, Vector3(0,-MAX_STEP_HEIGHT,0), body_test_result):
			_save_camera_pos_for_smoothing()
			var translate_y = body_test_result.get_travel().y
			self.position.y += translate_y
			apply_floor_snap()
			did_snap = true
	_snapped_to_stairs_last_frame = did_snap

func _snap_up_stairs_check(delta) -> bool:
	if not is_on_floor() and not _snapped_to_stairs_last_frame: return false

	if self.velocity.y > 0 or (self.velocity * Vector3(1,0,1)).length() == 0: return false
	var expected_move_motion = self.velocity * Vector3(1,0,1) * delta
	var step_pos_with_clearance = self.global_transform.translated(expected_move_motion + Vector3(0, MAX_STEP_HEIGHT * 2, 0))

	var down_check_result = KinematicCollision3D.new()
	if (self.test_move(step_pos_with_clearance, Vector3(0,-MAX_STEP_HEIGHT*2,0), down_check_result)
	and (down_check_result.get_collider().is_class("StaticBody3D") or down_check_result.get_collider().is_class("CSGShape3D"))):
		var step_height = ((step_pos_with_clearance.origin + down_check_result.get_travel()) - self.global_position).y

		if step_height > MAX_STEP_HEIGHT or step_height <= 0.01 or (down_check_result.get_position() - self.global_position).y > MAX_STEP_HEIGHT: return false
		%StairsAheadRayCast3D.global_position = down_check_result.get_position() + Vector3(0,MAX_STEP_HEIGHT,0) + expected_move_motion.normalized() * 0.1
		%StairsAheadRayCast3D.force_raycast_update()
		if %StairsAheadRayCast3D.is_colliding() and not is_surface_too_steep(%StairsAheadRayCast3D.get_collision_normal()):
			_save_camera_pos_for_smoothing()
			self.global_position = step_pos_with_clearance.origin + down_check_result.get_travel()
			apply_floor_snap()
			_snapped_to_stairs_last_frame = true
			return true
	return false
	
@onready var _original_capsule_height = $CollisionShape3D.shape.height
func _handle_crouch(delta) -> void:
	var was_crouched_last_frame = is_crouched
	if Input.is_action_pressed("Crouch"):
		is_crouched = true
	elif is_crouched and not self.test_move(self.global_transform, Vector3(0,CROUCH_TRANSLATE,0)):
		is_crouched = false
	
	var translate_y_if_possible := 0.0
	if was_crouched_last_frame != is_crouched and not is_on_floor() and not _snapped_to_stairs_last_frame:
		translate_y_if_possible = CROUCH_JUMP_ADD if is_crouched else -CROUCH_JUMP_ADD

	if translate_y_if_possible != 0.0:
		var result = KinematicCollision3D.new()
		self.test_move(self.global_transform, Vector3(0,translate_y_if_possible,0), result)
		self.position.y += result.get_travel().y
		%Head.position.y -= result.get_travel().y
		%Head.position.y = clampf(%Head.position.y, -CROUCH_TRANSLATE, 0)
	
	%Head.position.y = move_toward(%Head.position.y, -CROUCH_TRANSLATE if is_crouched else 0.0, 7.0 * delta)
	$CollisionShape3D.shape.height = _original_capsule_height - (CROUCH_TRANSLATE if is_crouched else 0.0)
	$CollisionShape3D.position.y = $CollisionShape3D.shape.height / 2 - 1
	
func _handle_noclip(delta) -> bool:
	if Input.is_action_just_pressed("debug_noclip") and OS.has_feature("debug"):
		noclip = !noclip
		noclip_speed_mult = 3.0
		
	%CollisionShape3D.disabled = noclip
		
	if not noclip:
		return false
		
	var speed = get_move_speed() * -noclip_speed_mult
	if Input.is_action_pressed("Shift"):
		speed *= 3.0
		
	self.velocity = cam_aligned_wish_dir * speed
	global_position += self.velocity * delta
		
				
	return true
	
func is_surface_too_steep(normal : Vector3) -> bool:
	return normal.angle_to(Vector3.UP) > self.floor_max_angle
	
func run_body_test_motion(from : Transform3D, motion : Vector3, result = null) -> bool:
	if not result: result = PhysicsTestMotionResult3D.new()
	var params = PhysicsTestMotionParameters3D.new()
	params.from= from
	params.motion = motion
	return PhysicsServer3D.body_test_motion(self.get_rid(), params, result)



func _handle_air_physics(delta) -> void:
	self.velocity.y -= ProjectSettings.get_setting("physics/3d/default_gravity") * delta
	self.velocity.y = clamp(self.velocity.y, -100 , INF)
	
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
	if is_on_floor() or _snapped_to_stairs_last_frame: 
		_last_frame_was_on_floor = Engine.get_physics_frames()
	
	var input_dir = Input.get_vector("D","A","S","W").normalized()
	#input and direction
	wish_dir = self.global_transform.basis * Vector3(-input_dir.x,0., -input_dir.y)
	cam_aligned_wish_dir = %Camera3D.global_transform.basis * Vector3(input_dir.x, 0., input_dir.y)
	
	_handle_crouch(delta)
	
	if not _handle_noclip(delta):
		if is_on_floor():
			if Input.is_action_just_pressed("Space") or (auto_bhop and Input.is_action_pressed("Space")):
				self.velocity.y  = jump_velocity
			_handle_ground_physics(delta)
		else:
			_handle_air_physics(delta)

		if not _snap_up_stairs_check(delta):
			move_and_slide()
			_snap_down_to_stairs_check()
	
	_handle_walk_sound()
	_handle_jump_sound()
	_slide_camera_smooth_back_to_origin(delta)

	print("FPSController: ", self.velocity)
	print("FPSController: ", self.global_position)
	print("FPSController: ", self.is_on_floor())
	print("FPSController: ", self.get_move_speed())

func _handle_flashlight():
	if !LightBool:
		light.light_energy = lightenergy
		flashlightsound.play()
		LightBool = true
	else:
		light.light_energy = 0
		flashlightsound.play()
		LightBool = false

func _handle_walk_sound():
	if is_on_floor() and self.velocity.length() > 0.1:
		if not walksound.playing:
			walksound.play()
	else:
		walksound.stop()
		
	if walksound.playing:
		walksound.pitch_scale = (self.velocity.length() / walk_speed)
	
func _handle_jump_sound():
	if Input.is_action_just_pressed("Space") or (auto_bhop and Input.is_action_pressed("Space")):
		if is_on_floor():
			jumpingsound.play()
