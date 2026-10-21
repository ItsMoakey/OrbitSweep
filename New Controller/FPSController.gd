extends CharacterBody3D

@export var look_sensitivity : float = 0.006
@export var controller_look_sensitivity : float = 0.05
@export var jump_velocity := 6.0
@export var jump_cooldown := 0.18
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
@export var lightenergy := 2.5

var wish_dir := Vector3.ZERO
var cam_aligned_wish_dir := Vector3.ZERO
var LightBool := false

const CROUCH_TRANSLATE = 0.7
const CROUCH_JUMP_ADD = CROUCH_TRANSLATE * 0.9
var is_crouched := false

var noclip_speed_mult := 3.0
var noclip := false
var _jump_cooldown_timer := 0.0

const MAX_STEP_HEIGHT = 0.5
var _snapped_to_stairs_last_frame := false
var _last_frame_was_on_floor = -INF

var health := 100
var is_dead := false

# ---------------- Jetpack / Space Engineers style flight ----------------
# Controls use the actions configured in project.godot's Input Map:
#   Jetpack, Dampeners, Q/E, W/A/S/D, Space, Crouch, Shift, Grab/RMB, LMB
@export_group("Jetpack")
@export var jetpack_accel := 9.81           # m/s^2 thrust per axis
@export var jetpack_max_speed := 100.0        # m/s per axis
@export var jetpack_boost_mult := 3.0        # while holding Shift
@export var dampener_accel := 16.0           # braking power when no input on an axis
@export var roll_speed := 1.8                # rad/s
@export var flight_gravity_scale := 0.0      # 0 = space, 1 = gravity still pulls you
@export var level_speed := 6.0               # how fast the body rights itself after jetpack off
@export var dampeners_start_on := true
@export var always_boost := false;

@export_group("Rigidbody Interaction")
@export_range(0.0, 1.0) var push_force := 0.25  # fraction of the speed gap closed per physics frame (higher = pushes harder, 1 = matches your speed instantly)
@export var player_push_mass := 80.0         # lighter bodies move easily, heavier ones barely budge
@export var push_min_mass_ratio := 0.25      # bodies 4x heavier than you (ratio < this) aren't pushed at all
@export var grab_reach := 3.0                # how far you can reach to grab
@export var grab_min_distance := 1.5
@export var grab_max_distance := 3.0         # scroll wheel adjusts hold distance in between
@export var grab_pull_strength := 12.0       # how hard the held object chases the hold point
@export var grab_max_speed := 15.0
@export var grab_max_mass := 100.0           # can't grab anything heavier
@export var grab_break_distance := 2.5       # object gets stuck / left behind -> let go
@export var throw_speed := 14.0

var held_body : RigidBody3D = null
var grab_distance := 2.0

var flying := false
var leveling := false
var _level_pitch_target := 0.0
var dampeners_on := true

func get_move_speed() -> float:
	if is_crouched:
		return walk_speed * 0.8
	return sprint_speed if Input.is_action_pressed("Shift") else walk_speed

func _ready():
	dampeners_on = dampeners_start_on
	
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
			if flying:
				# Free 6DOF look: rotate the whole body on its own axes
				_rotate_about_head(Vector3.UP, -event.relative.x * look_sensitivity)
				_rotate_about_head(Vector3.RIGHT, -event.relative.y * look_sensitivity)
			else:
				rotate_y(-event.relative.x * look_sensitivity)
				if leveling:
					# Keep the leveling target in sync with the mouse.
					_level_pitch_target = clamp(_level_pitch_target - event.relative.y * look_sensitivity, deg_to_rad(-89), deg_to_rad(89))
				%Camera3D.rotate_x(-event.relative.y * look_sensitivity)
				%Camera3D.rotation.x = clamp(%Camera3D.rotation.x,deg_to_rad(-89), deg_to_rad(89))
	
	if event is InputEventMouseButton and event.is_pressed():
		if held_body != null:
			# scroll while holding = push the object away / pull it closer
			if event.button_index == MOUSE_BUTTON_WHEEL_UP:
				grab_distance = minf(grab_max_distance, grab_distance + 0.2)
			elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				grab_distance = maxf(grab_min_distance, grab_distance - 0.2)
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			noclip_speed_mult = min(100.0, noclip_speed_mult * 1.1)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			noclip_speed_mult = max(0.1, noclip_speed_mult * 0.9)

	if Input.is_action_just_pressed("F"):
		_handle_flashlight()

# Rotates the body around the camera position (not the capsule origin),
# so the view turns in place instead of orbiting around the feet/body.
func _rotate_about_head(local_axis: Vector3, angle: float) -> void:
	var pivot : Vector3 = %Camera3D.global_position
	rotate_object_local(local_axis, angle)
	global_position += pivot - %Camera3D.global_position

func _flat_forward() -> Vector3:
	var fwd := -global_transform.basis.z
	var flat := Vector3(fwd.x, 0.0, fwd.z)
	if flat.length() < 0.05:
		var up_axis := global_transform.basis.y
		flat = Vector3(-up_axis.x, 0.0, -up_axis.z) if fwd.y > 0.0 else Vector3(up_axis.x, 0.0, up_axis.z)
	return flat.normalized()

func _set_flying(value: bool) -> void:
	if value == flying:
		return
	flying = value
	if flying:
		leveling = false
		motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
		is_crouched = false
		$CollisionShape3D.shape.height = _original_capsule_height
		$CollisionShape3D.position.y = $CollisionShape3D.shape.height / 2 - 1
		_snapped_to_stairs_last_frame = false
	else:
		# don't snap upright: smoothly level the body in _handle_leveling
		_level_pitch_target = 0.0
		leveling = true
		motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED
	print("Jetpack: ", "ON" if flying else "OFF")

func _handle_leveling(delta: float) -> void:
	var pivot : Vector3 = %Camera3D.global_position
	var t := 1.0 - exp(-level_speed * delta)
	var target := Basis.looking_at(_flat_forward(), Vector3.UP)
	var cur_q := Quaternion(global_transform.basis.orthonormalized())
	var target_q := Quaternion(target)
	global_transform.basis = Basis(cur_q.slerp(target_q, t))
	global_position += pivot - %Camera3D.global_position
	%Camera3D.rotation.x = lerp_angle(%Camera3D.rotation.x, _level_pitch_target, t)
	if cur_q.angle_to(target_q) < 0.01 and absf(angle_difference(%Camera3D.rotation.x, _level_pitch_target)) < 0.01:
		global_transform.basis = target
		global_position += pivot - %Camera3D.global_position
		%Camera3D.rotation.x = _level_pitch_target
		leveling = false

func _handle_flight(delta: float) -> void:
	%Camera3D.rotation.x = lerp_angle(%Camera3D.rotation.x, 0.0, 1.0 - exp(-level_speed * delta))

	# --- roll ---
	var roll := Input.get_action_strength("E") - Input.get_action_strength("Q")
	if roll != 0.0:
		_rotate_about_head(Vector3.FORWARD, roll * roll_speed * delta)
	global_transform.basis = global_transform.basis.orthonormalized()

	# ease the head back up if we were crouched when the jetpack came on
	%Head.position.y = move_toward(%Head.position.y, 0.0, 7.0 * delta)

	# --- thrust input in local space (x = right, y = up, z = back) ---
	var input_dir := Input.get_vector("D","A","S","W")   # x = A-D, y = W-S
	var thrust := Vector3(
		-input_dir.x,
		Input.get_action_strength("Space") - Input.get_action_strength("Crouch"),
		-input_dir.y
	)
	var boost := jetpack_boost_mult if Input.is_action_pressed("Shift") or always_boost else 1.0
	var max_speed := jetpack_max_speed #* boost

	# --- work in local space so dampeners act per axis, like Space Engineers ---
	# gravity goes in first so dampeners can hold you hovering against it
	if flight_gravity_scale > 0.0:
		velocity.y -= ProjectSettings.get_setting("physics/3d/default_gravity") * flight_gravity_scale * delta

	var local_vel := global_transform.basis.inverse() * velocity
	for i in 3:
		var axis_in : float = thrust[i]
		if absf(axis_in) > 0.01:
			var target : float = axis_in * max_speed
			# only push toward the target, never fight a faster existing speed
			if (axis_in > 0.0 and local_vel[i] < target) or (axis_in < 0.0 and local_vel[i] > target):
				local_vel[i] = move_toward(local_vel[i], target, jetpack_accel * boost * delta)
			elif dampeners_on:
				local_vel[i] = move_toward(local_vel[i], target, dampener_accel * delta)
		elif dampeners_on:
			local_vel[i] = move_toward(local_vel[i], 0.0, dampener_accel * delta)

	velocity = global_transform.basis * local_vel

	_push_away_rigid_bodies() # Call before move_and_slide()
	var pre_slide_velocity := velocity
	move_and_slide()

	# Hitting a static wall kills the velocity pointing into it, so thrust can't keep
	# building up while you're pressed against it (and then fling you when you turn away).
	# Sliding along the wall is kept. Rigid bodies are skipped so pushing them still works.
	var wall_hit := false
	var cleaned_velocity := pre_slide_velocity
	for i in get_slide_collision_count():
		var c := get_slide_collision(i)
		if c.get_collider() is RigidBody3D:
			continue
		var n := c.get_normal()
		var into_wall := cleaned_velocity.dot(n)
		if into_wall < 0.0:
			cleaned_velocity -= n * into_wall
			wall_hit = true
	if wall_hit:
		velocity = cleaned_velocity

	# camera stays level with the body, no bob while flying
	%Camera3D.transform.origin = %Camera3D.transform.origin.lerp(Vector3.ZERO, 10.0 * delta)
	_slide_camera_smooth_back_to_origin(delta)
		
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
	
	if flying:
		_rotate_about_head(Vector3.UP, -_cur_controller_look.x * controller_look_sensitivity)
		_rotate_about_head(Vector3.RIGHT, -_cur_controller_look.y * controller_look_sensitivity)
		return
	rotate_y(-_cur_controller_look.x * controller_look_sensitivity)
	if leveling and _cur_controller_look.length() > 0.01:
		_level_pitch_target = clamp(_level_pitch_target - _cur_controller_look.y * controller_look_sensitivity, deg_to_rad(-89), deg_to_rad(89))
	%Camera3D.rotate_x(-_cur_controller_look.y * controller_look_sensitivity)
	%Camera3D.rotation.x = clamp(%Camera3D.rotation.x,deg_to_rad(-89), deg_to_rad(89))
	
func _process(delta):
	_handle_controller_look_input(delta)
	if Input.is_action_just_pressed("Jetpack"):
		_set_flying(not flying)
	if Input.is_action_just_pressed("Dampeners"):
		dampeners_on = not dampeners_on
		print("Inertial dampeners: ", "ON" if dampeners_on else "OFF")
	
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
	var target_speed = get_move_speed()
	var cur_speed_in_wish_dir = self.velocity.dot(wish_dir)
	var speed_till_target = target_speed - cur_speed_in_wish_dir
	if abs(speed_till_target) > 0.001:
		var accel_speed = ground_accel * target_speed * delta
		accel_speed = min(accel_speed, abs(speed_till_target))
		if speed_till_target > 0:
			self.velocity += accel_speed * wish_dir
		else:
			self.velocity -= accel_speed * wish_dir
	
	var control = max(self.velocity.length(), ground_decel)
	var drop = control * ground_friction * delta
	var new_speed = max(self.velocity.length() - drop, 0.0)
	if self.velocity.length() > 0:
		new_speed /= self.velocity.length()
	self.velocity *= new_speed
	
	_headbob_effect(delta)

func _physics_process(delta):
	if _jump_cooldown_timer > 0.0:
		_jump_cooldown_timer = max(0.0, _jump_cooldown_timer - delta)

	if is_dead:
		_release_grab()
		self.velocity = Vector3.ZERO
		wish_dir = Vector3.ZERO
		cam_aligned_wish_dir = Vector3.ZERO
		walksound.stop()
		return

	_handle_grab(delta)

	if flying:
		_handle_flight(delta)
		walksound.stop()
		return

	if leveling:
		_handle_leveling(delta)

	if is_on_floor() or _snapped_to_stairs_last_frame:
		_last_frame_was_on_floor = Engine.get_physics_frames()

	var input_dir = Input.get_vector("D","A","S","W").normalized()
	#input and direction
	wish_dir = self.global_transform.basis * Vector3(-input_dir.x,0., -input_dir.y)
	cam_aligned_wish_dir = %Camera3D.global_transform.basis * Vector3(input_dir.x, 0., input_dir.y)

	_handle_crouch(delta)
	
	if not _handle_noclip(delta):
		if is_on_floor():
			_handle_jump_sound()
			var jump_pressed = Input.is_action_just_pressed("Space") or (auto_bhop and Input.is_action_pressed("Space"))
			if jump_pressed and _jump_cooldown_timer <= 0.0:
				self.velocity.y  = jump_velocity
				_jump_cooldown_timer = jump_cooldown
			_handle_ground_physics(delta)
		else:
			_handle_air_physics(delta)

		if not _snap_up_stairs_check(delta):
			_push_away_rigid_bodies() # Call before move_and_slide()
			move_and_slide()
			_snap_down_to_stairs_check()
	
	_handle_walk_sound()
	_slide_camera_smooth_back_to_origin(delta)

	# print("FPSController: ", self.velocity)
	# print("FPSController: ", self.global_position)
	# print("FPSController: ", self.is_on_floor())
	# print("FPSController: ", self.get_move_speed())
	# var horizontal_velocity = abs(Vector3(self.velocity.x, 0.0, self.velocity.z).length())
	# print("FPSController | horizontal_velocity=", horizontal_velocity)

# ---------------- RigidBody push & grab ----------------
# Source-style push. Must be called BEFORE move_and_slide(): at that point
# get_slide_collision() still holds last frame's contacts and `velocity` is still
# the full velocity we're about to move with (move_and_slide would cancel the part
# pointing into the body, which is why reading it afterwards gives a weak push).
func _push_away_rigid_bodies() -> void:
	for i in get_slide_collision_count():
		var c := get_slide_collision(i)
		var body := c.get_collider() as RigidBody3D
		if body == null or body == held_body:
			continue
		var push_dir := -c.get_normal()
		# On the ground, move_and_slide() zeroes the velocity pointing into the body every
		# frame, and ground friction eats most of what's re-added, so `velocity` alone is
		# only ~0.5 m/s while walking into a box. Use the speed the player is *trying* to
		# move at instead whenever that's higher.
		var player_vel := self.velocity
		if not flying and not noclip:
			var intended := wish_dir * get_move_speed()
			if intended.dot(push_dir) > player_vel.dot(push_dir):
				player_vel = intended
		# How much velocity the object needs to increase to match player velocity in the push direction
		var velocity_diff_in_push_dir := player_vel.dot(push_dir) - body.linear_velocity.dot(push_dir)
		# Only count velocity towards push dir, away from character
		velocity_diff_in_push_dir = maxf(0.0, velocity_diff_in_push_dir)
		# Objects with more mass than us are harder to push. Doesn't make sense to push faster than we are going
		var mass_ratio := minf(1.0, player_push_mass / maxf(body.mass, 0.001))
		# Don't push the object at all if it's much heavier than us
		if mass_ratio < push_min_mass_ratio:
			continue
		# Don't push object from above/below
		push_dir.y = 0.0
		# Fraction of the speed difference we close this frame (never > 1, so a body can't
		# be launched faster than we're moving). Scaled by body.mass so light and heavy
		# bodies react the same way instead of light ones being flung.
		var match_fraction := minf(1.0, mass_ratio * push_force)
		var delta_v := push_dir * velocity_diff_in_push_dir * match_fraction
		body.apply_impulse(delta_v * body.mass, c.get_position() - body.global_position)

func _release_grab() -> void:
	if held_body != null and is_instance_valid(held_body):
		held_body.remove_collision_exception_with(self)
	held_body = null

func _try_grab() -> void:
	var cam : Camera3D = %Camera3D
	var from := cam.global_position
	var to := from - cam.global_basis.z * grab_reach
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return
	var body := hit.collider as RigidBody3D
	if body == null or body.mass > grab_max_mass:
		return
	held_body = body
	held_body.add_collision_exception_with(self)   # held object can't shove or lift the player
	grab_distance = clampf(from.distance_to(hit.position), grab_min_distance, grab_max_distance)

func _handle_grab(_delta: float) -> void:
	if held_body != null and not is_instance_valid(held_body):
		held_body = null

	var cam : Camera3D = %Camera3D
	var cam_forward := -cam.global_basis.z

	if Input.is_action_just_pressed("Grab"):
		if held_body == null:
			_try_grab()
		else:
			_release_grab()
		return

	if held_body == null:
		return

	if Input.is_action_just_pressed("LMB"):
		var thrown := held_body
		_release_grab()
		thrown.linear_velocity = cam_forward * throw_speed + velocity
		thrown.sleeping = false
		return

	var hold_point := cam.global_position + cam_forward * grab_distance
	var to_target := hold_point - held_body.global_position
	if to_target.length() > grab_break_distance:
		_release_grab()
		return

	held_body.sleeping = false
	held_body.linear_velocity = (to_target * grab_pull_strength).limit_length(grab_max_speed) + velocity
	held_body.angular_velocity *= 0.8

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
	if is_on_floor() and self.velocity.length() > 0.1 and not noclip :
		if not walksound.playing:
			walksound.play()
	else:
		walksound.stop()
		
	if walksound.playing:
		walksound.pitch_scale = (self.velocity.length() / walk_speed)
	
func _handle_jump_sound():
	var jump_pressed = Input.is_action_just_pressed("Space") or (auto_bhop and Input.is_action_pressed("Space"))
	if jump_pressed and _jump_cooldown_timer <= 0.0 and is_on_floor() and not noclip:
		jumpingsound.play()

func _health(amount):
	health += amount
	print("Player health: ", health)
	if health <= 0 and not is_dead:
		is_dead = true
		print("Player has died.")
		await get_tree().create_timer(2).timeout
		get_tree().reload_current_scene()
