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
## Physics layers scanned for RigidBody3D props that should go through.
@export_flags_3d_physics var body_mask := 1
## The portal image is rendered at 1/headroom brightness and scaled back up in the shader,
## so highlights up to this many times white survive. Higher keeps more of them but
## costs a little precision in the dark end (the view texture is 8 bit).
@export var hdr_headroom := 4.0

const ZONE_FRONT := 2.0 # prop detection volume: this far in front of the plane...
const ZONE_BACK := 1.0  # ...and this far behind it
const THIN_DEPTH := 0.002 # portal surface depth when the player's camera is not near it
const LANE_MARGIN := 0.5  # a held object counts as "in the portal" this far outside the opening...
const LANE_DEPTH := 4.0   # ...and up to this far in front of it (a bit over the longest hold distance)

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
var _depth := THIN_DEPTH # current depth of the portal surface box behind the plane

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
	# A box rather than a quad: it gets deeper behind the portal plane while the player's
	# camera is close (see _update_screen_depth). Unit depth, scaled in Z.
	var box := BoxMesh.new()
	box.size = Vector3(size.x, size.y, 1.0)
	_mesh.mesh = box
	_mesh.rotation = Vector3.ZERO
	_mesh.scale = Vector3(1.0, 1.0, _depth)
	_mesh.position = Vector3(0.0, 0.0, _depth * 0.5) # front face stays on the portal plane
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
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
	_mesh.visible = false # shown by _process once there's a view to show

func _process(_delta: float) -> void:
	if Engine.is_editor_hint() or target == null or _camera == null:
		return
	var main_cam := get_viewport().get_camera_3d()
	if main_cam == null:
		return

	# Only show and render the portal while the viewer is on the visible (front) side and close
	# enough. Otherwise the surface is hidden outright: a stopped view would leave it showing
	# the last frame it rendered, and the portal should be transparent from behind.
	var my_inv := _xf().affine_inverse()
	var viewer_local := my_inv * main_cam.global_position
	var active := viewer_local.z < 0.0 and main_cam.global_position.distance_to(global_position) < max_render_distance
	if _mesh.visible != active:
		_mesh.visible = active
	_update_screen_depth(main_cam, viewer_local.z if active else INF)
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

# The player camera's near plane is a small rectangle floating in front of the lens. Close to
# the portal its corners cross the portal plane before the camera does, and the clipped part
# of the screen would show whatever is really behind the portal for a few frames (worst when
# looking sideways, where the near plane's edge leads the camera by the most). So while the
# camera is close, the portal surface is a box reaching back from the plane by the distance
# from the lens to a near-plane corner: anything the near plane pokes into is inside the box,
# and shows the portal image like the rest of the surface. Away from the portal it collapses
# back to a flat quad so it can't be seen sticking out of a thin wall.
func _update_screen_depth(cam: Camera3D, cam_z: float) -> void:
	var near := cam.near
	var vs := get_viewport().get_visible_rect().size
	var aspect := vs.x / maxf(vs.y, 1.0)
	var half_a := near * tan(deg_to_rad(cam.fov * 0.5))
	var half_w := half_a
	var half_h := half_a
	if cam.keep_aspect == Camera3D.KEEP_WIDTH:
		half_h = half_a / aspect
	else:
		half_w = half_a * aspect
	var reach := Vector3(half_w, half_h, near).length() * 1.2 + 0.01
	_set_depth(reach if absf(cam_z) < reach * 2.0 else THIN_DEPTH)

func _set_depth(d: float) -> void:
	if is_equal_approx(d, _depth):
		return
	_depth = d
	_mesh.scale = Vector3(1.0, 1.0, d)
	_mesh.position = Vector3(0.0, 0.0, d * 0.5)

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

# The transform that carries a point from this portal's side to the target's side, whether or
# not anything is passing through the opening right now (null if there's no target). The
# player controller uses it to keep a held object attached to the hold point while the
# object is on the far side and the hold point has already come back out in front of this
# portal, e.g. backing away from the portal. The object is then pulled back through instead
# of being dragged across the map and dropped for being too far from the hold point.
func map_transform() -> Variant:
	if target == null:
		return null
	return target._xf() * _flip * _xf().affine_inverse()

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

func _physics_process(_delta: float) -> void:
	if Engine.is_editor_hint() or target == null or not teleport_enabled:
		return
	_update_bodies()
	if player == null:
		player = _find_player(get_tree().root)
		if player == null:
			return

	# The swap happens when the player's camera crosses the portal plane inside the opening,
	# whichever way it is looking. The camera, not the body, because the camera is what the
	# eye sees. The old flicker came from the camera's near plane poking through the portal
	# plane before the camera did; _update_screen_depth covers that, so there's no need to
	# swap early or late depending on the view direction.
	var cam := get_viewport().get_camera_3d()
	var probe := cam.global_position if cam != null else player.global_position
	var local := _xf().affine_inverse() * probe
	if _has_last and _last_local.z < 0.0 and local.z >= 0.0:
		# crossed the plane this tick, check where on the plane
		var k := _last_local.z / (_last_local.z - local.z)
		var cross := _last_local.lerp(local, k)
		if absf(cross.x) <= size.x * 0.5 and absf(cross.y) <= size.y * 0.5:
			_teleport(player)
			return
	_last_local = local
	_has_last = true

# What the player is holding only stays held across the swap if it goes through with them:
# lined up with this portal's opening (still on this side, about to follow) or with the
# target's opening (already came through). Otherwise, e.g. strafing through sideways while
# the cube is held off to the side, it's let go instead of being dragged around.
func _drop_held_if_left_behind(body: Node) -> void:
	var held: Variant = body.get("held_body")
	if held == null or not is_instance_valid(held) or not (held is RigidBody3D):
		return
	var pos: Vector3 = (held as RigidBody3D).global_position
	if _in_lane(pos) or target._in_lane(pos):
		return
	if body.has_method("_release_grab"):
		body.call("_release_grab")

func _in_lane(world_pos: Vector3) -> bool:
	var l := _xf().affine_inverse() * world_pos
	return absf(l.x) <= size.x * 0.5 + LANE_MARGIN \
			and absf(l.y) <= size.y * 0.5 + LANE_MARGIN \
			and l.z >= -LANE_DEPTH and l.z <= 1.0

func _teleport(body: CharacterBody3D) -> void:
	_drop_held_if_left_behind(body)
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
	var cam := get_viewport().get_camera_3d()
	var probe := cam.global_position if cam != null else body.global_position
	target._last_local = target._xf().affine_inverse() * probe
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