@tool
class_name Portal
extends Node3D
## Seamless Source-style portal. Place two, point each one's `target` at the other.
##
## Convention: the portal FACES local -Z. The visible side (where you stand to look
## into it) is the -Z side. Walking from -Z to +Z through the opening teleports you
## to the target, coming out of its -Z side.
##
## Everything it needs (SubViewport, camera, surface mesh) is built in _ready(),
## so the scene is just a Node3D with this script.

signal teleported(body: Node3D)

const PORTAL_LAYER := 20 # render layer for portal surfaces, hidden from portal cameras
const VIEW_SHADER := preload("res://util/portal.gdshader")

@export var target: Portal
@export var size := Vector2(2.5, 3.0): set = _set_size
@export var teleport_enabled := true
## Optional. If empty, the first CharacterBody3D in the tree is used (same as door_airlock.gd).
@export var player: CharacterBody3D
@export var max_render_distance := 60.0
## How far in front of the target plane the virtual camera's near clip sits.
@export var near_margin := 0.02
## Extra distance in front of the plane at which the teleport fires, on top of what the
## camera's near plane and the player's speed already need. Raise it if flicker remains.
@export var teleport_lead := 0.05
## Physics layers scanned for RigidBody3D props that should go through.
@export_flags_3d_physics var body_mask := 1
## The portal image is rendered at 1/headroom brightness and scaled back up in the shader,
## so highlights up to this many times white survive. Higher keeps more of them but
## costs a little precision in the dark end (the view texture is 8 bit).
@export var hdr_headroom := 4.0

const ZONE_FRONT := 2.0 # prop detection volume: this far in front of the plane...
const ZONE_BACK := 1.0  # ...and this far behind it

var _viewport: SubViewport
var _camera: Camera3D
var _mesh: MeshInstance3D
var _mat: ShaderMaterial
var _flip := Transform3D(Basis(Vector3.UP, PI), Vector3.ZERO)
var _last_local := Vector3.ZERO
var _has_last := false
var _zone: Area3D
var _body_last := {} # RigidBody3D -> its position in this portal's local space last tick
var _src_env: Environment
var _env_ready := false

func _ready() -> void:
	_build_mesh()
	if Engine.is_editor_hint():
		return
	process_priority = 1000          # update after the player's camera has moved
	process_physics_priority = 100   # teleport after the player has moved this tick
	add_to_group("portals") # the player controller looks portals up by this group
	_build_view()
	_build_zone()

func _set_size(value: Vector2) -> void:
	size = value
	if is_node_ready():
		_build_mesh()

# Transform without scale, so scaled instances don't skew the portal math.
func _xf() -> Transform3D:
	return global_transform.orthonormalized()

func _build_mesh() -> void:
	if _mesh == null:
		_mesh = MeshInstance3D.new()
		_mesh.name = "Surface"
		add_child(_mesh)
	var quad := QuadMesh.new()
	quad.size = size
	_mesh.mesh = quad
	_mesh.rotation = Vector3(0.0, PI, 0.0) # QuadMesh faces +Z, we want it to face -Z
	_mesh.layers = 1 << (PORTAL_LAYER - 1)
	if Engine.is_editor_hint():
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.albedo_color = Color(0.2, 0.8, 1.0, 0.3)
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		_mesh.material_override = m

func _build_view() -> void:
	_viewport = SubViewport.new()
	_viewport.name = "View"
	_viewport.size = Vector2i(1280, 720)
	_viewport.msaa_3d = Viewport.MSAA_DISABLED
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_viewport)

	_camera = Camera3D.new()
	# Portal cameras don't draw portal surfaces: no recursion, one level deep only.
	_camera.cull_mask = 0xFFFFF & ~(1 << (PORTAL_LAYER - 1))
	_viewport.add_child(_camera)

	_mat = ShaderMaterial.new()
	_mat.shader = VIEW_SHADER
	_mat.set_shader_parameter("view_tex", _viewport.get_texture())
	_mesh.material_override = _mat

func _process(_delta: float) -> void:
	if Engine.is_editor_hint() or target == null or _camera == null:
		return
	var main_cam := get_viewport().get_camera_3d()
	if main_cam == null:
		return

	# Only render when the viewer is on the visible side and close enough.
	var my_inv := _xf().affine_inverse()
	var viewer_local := my_inv * main_cam.global_position
	var active := viewer_local.z < 0.5 and main_cam.global_position.distance_to(global_position) < max_render_distance
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if active else SubViewport.UPDATE_DISABLED
	if not active:
		return

	var vp_size := Vector2i(get_viewport().get_visible_rect().size)
	if _viewport.size != vp_size:
		_viewport.size = vp_size

	var world_env := get_world_3d().environment
	if not _env_ready or world_env != _src_env:
		_src_env = world_env
		_env_ready = true
		_apply_view_environment(world_env)

	# Viewer relative to this portal -> same spot relative to the target, flipped 180 about Y
	# (looking at +Z here means looking out along -Z there).
	var tgt := target._xf()
	var t := tgt * _flip * my_inv * main_cam.global_transform
	_camera.global_transform = t
	_camera.fov = main_cam.fov
	_camera.keep_aspect = main_cam.keep_aspect
	_camera.far = main_cam.far

	# The virtual camera sits *behind* the target's plane, and the wall the target is mounted
	# in would block the view, so the near plane has to cut it off. A near plane is
	# perpendicular to the view, not parallel to the portal, so putting it at the
	# camera-to-plane distance clips real content next to the portal whenever you look at it
	# at an angle. Instead use the depth of the nearest corner of the target's opening:
	# everything visible through the opening is at least that far away, so nothing that
	# should show gets clipped. The trade-off is that at steep angles a sliver of geometry
	# just behind the target plane can show on the far side (a real fix needs an oblique
	# projection, which Camera3D doesn't expose).
	var inv_t := t.affine_inverse()
	var half := target.size * 0.5
	var min_depth := INF
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			var corner := tgt * Vector3(sx * half.x, sy * half.y, 0.0)
			min_depth = minf(min_depth, -(inv_t * corner).z)
	_camera.near = clampf(min_depth - near_margin, 0.05, _camera.far - 1.0)

# The portal image would be tone mapped twice: once inside the SubViewport and again when
# the main view draws the quad. So the portal camera gets a copy of the world environment
# with tone mapping set to linear, and the main view's own tone mapping does the real work.
# Linear output is clamped to 0..1, so the camera renders at 1/headroom exposure and the
# shader multiplies it back, which keeps highlights up to `hdr_headroom` times white.
# Glow and colour adjustments are turned off in the copy because the main view applies
# them to the quad anyway.
func _apply_view_environment(src: Environment) -> void:
	if src == null:
		_camera.environment = null
		_mat.set_shader_parameter("headroom", 1.0)
		return
	var env := src.duplicate() as Environment
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.tonemap_exposure = 1.0 / hdr_headroom
	env.glow_enabled = false
	env.adjustment_enabled = false
	_camera.environment = env
	_mat.set_shader_parameter("headroom", hdr_headroom)

func _build_zone() -> void:
	_zone = Area3D.new()
	_zone.name = "BodyZone"
	_zone.monitorable = false
	_zone.collision_layer = 0
	_zone.collision_mask = body_mask
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(size.x, size.y, ZONE_FRONT + ZONE_BACK)
	shape.shape = box
	shape.position = Vector3(0.0, 0.0, (ZONE_BACK - ZONE_FRONT) * 0.5)
	_zone.add_child(shape)
	add_child(_zone)

# Returns the transform that carries a point from this portal's side to the target's side
# if the segment from -> to passes through the opening from the front, else null. Used by
# the player controller so a held object is pulled to where the hold point comes out of
# the target portal.
func through_transform(from: Vector3, to: Vector3) -> Variant:
	if target == null:
		return null
	var inv := _xf().affine_inverse()
	var a := inv * from
	var b := inv * to
	if a.z >= 0.0 or b.z < 0.0:
		return null
	var c := a.lerp(b, a.z / (a.z - b.z))
	if absf(c.x) > size.x * 0.5 or absf(c.y) > size.y * 0.5:
		return null
	return target._xf() * _flip * inv

func _update_bodies() -> void:
	if _zone == null:
		return
	var inv := _xf().affine_inverse()
	var seen := {}
	for body in _zone.get_overlapping_bodies():
		var rb := body as RigidBody3D
		if rb == null:
			continue
		var local := inv * rb.global_position
		seen[rb] = local
		if not _body_last.has(rb):
			continue
		var last: Vector3 = _body_last[rb]
		if last.z < 0.0 and local.z >= 0.0:
			var k := last.z / (last.z - local.z)
			var cross := last.lerp(local, k)
			if absf(cross.x) <= size.x * 0.5 and absf(cross.y) <= size.y * 0.5:
				_teleport_body(rb)
				seen.erase(rb)
	_body_last = seen

func _teleport_body(body: RigidBody3D) -> void:
	var m := target._xf() * _flip * _xf().affine_inverse()
	var xf := m * body.global_transform
	xf.basis = xf.basis.orthonormalized()
	# Set the state through the physics server: assigning global_transform on a
	# RigidBody3D mid-simulation is unreliable.
	var rid := body.get_rid()
	var lin := m.basis * body.linear_velocity
	var ang := m.basis * body.angular_velocity
	PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_TRANSFORM, xf)
	PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, lin)
	PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, ang)
	body.sleeping = false
	# seed the target so the body isn't sent straight back
	target._body_last[body] = target._xf().affine_inverse() * xf.origin
	teleported.emit(body)

func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint() or target == null or not teleport_enabled:
		return
	_update_bodies()
	if player == null:
		player = _find_player(get_tree().root)
		if player == null:
			return

	# Where to swap depends on which way the camera is looking, because the swap is only
	# invisible if what's on screen is the same just before and just after.
	# - Looking INTO the portal: swap slightly before the plane. Waiting for the exact
	#   crossing lets the camera's near plane clip the quad and flash the hole behind it.
	#   The quad fills the screen at that distance, so going early can't be seen.
	# - Looking AWAY (backing in): swap slightly after the plane. Early would drop the
	#   camera behind the target looking away from it, showing the wrong world until it
	#   backed out. Late lands it just in front of the target looking at its quad, which
	#   shows the world you just left.
	# In between the offset slides smoothly through the plane itself.
	var lead := _trigger_lead(delta)
	var facing := 1.0
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		facing = (-cam.global_basis.z).dot(_xf().basis.z) # +1 = looking straight into the portal
	var trigger_z := -lead * facing
	var local := _xf().affine_inverse() * player.global_position
	var approaching := _has_last and local.z > _last_local.z
	if approaching and local.z >= trigger_z and local.z < trigger_z + 0.5 \
			and absf(local.x) <= size.x * 0.5 and absf(local.y) <= size.y * 0.5:
		_teleport(player)
		return
	_last_local = local
	_has_last = true

# Distance from the plane at which to teleport: how far the near plane reaches sideways,
# plus what the player covers in one physics tick, plus a small fixed margin.
func _trigger_lead(delta: float) -> float:
	var lead := teleport_lead
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		var vp := get_viewport().get_visible_rect().size
		var half_h := cam.near * tan(deg_to_rad(cam.fov * 0.5))
		lead += half_h * (vp.x / maxf(vp.y, 1.0)) * 1.5
	lead += player.velocity.length() * delta
	return lead

func _teleport(body: CharacterBody3D) -> void:
	var m := target._xf() * _flip * _xf().affine_inverse()
	var new_xf := m * body.global_transform
	new_xf.basis = new_xf.basis.orthonormalized()
	var vel := m.basis * body.velocity

	# The FPS controller keeps the body yaw-only while walking (pitch lives on the camera),
	# so drop any tilt picked up from non-upright portals unless the jetpack is on.
	var is_flying: bool = body.get("flying") == true
	if not is_flying:
		var fwd := -new_xf.basis.z
		fwd.y = 0.0
		if fwd.length() > 0.001:
			new_xf.basis = Basis.looking_at(fwd.normalized(), Vector3.UP)

	body.global_transform = new_xf
	body.velocity = vel

	_has_last = false
	target._last_local = target._xf().affine_inverse() * body.global_position
	target._has_last = true
	teleported.emit(body)

func _find_player(node: Node) -> CharacterBody3D:
	for child in node.get_children():
		if child is CharacterBody3D:
			return child
		var found := _find_player(child)
		if found:
			return found
	return null