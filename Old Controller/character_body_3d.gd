extends CharacterBody3D


const SPEED = 5.0
const SPRINTSPEED = 7.0
const JUMP_VELOCITY = 4.5
const SENSITIVITY = 0.03
var LIGHT = false

@onready var head = $Head
@onready var camera = $Head/Camera3D
@onready var light = $Head/Camera3D/SpotLight3D

func _ready() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		head.rotate_y(-event.relative.x * SENSITIVITY)
		camera.rotate_x(-event.relative.y * SENSITIVITY)
		camera.rotation.x = (clamp(camera.rotation.x , deg_to_rad(-89), deg_to_rad(89)))
	
	if Input.is_action_just_pressed("F"):
		if !LIGHT:
			light.light_energy = 5
			LIGHT = true
		else:
			light.light_energy = 0
			LIGHT = false
		

func _physics_process(delta: float) -> void:
	# Add the gravity.
	if not is_on_floor():
		velocity += get_gravity() * delta

	# Handle jump.
	if Input.is_action_just_pressed("Space") and is_on_floor():
		velocity.y = JUMP_VELOCITY

	# Get the input direction and handle the movement/deceleration.
	# As good practice, you should replace UI actions with custom gameplay actions.
	var input_dir = Input.get_vector("A", "D", "W", "S")
	var direction = (head.transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	
	if direction:
		if !Input.is_action_pressed("Shift"):
			velocity.x = direction.x * SPEED
			velocity.z = direction.z * SPEED
			print("notsprint", velocity)
		else:
			velocity.x = direction.x * SPRINTSPEED
			velocity.z = direction.z * SPRINTSPEED
			print("sprint" , velocity)
	else:
		velocity.x = 0;
		velocity.z = 0;

	move_and_slide()
