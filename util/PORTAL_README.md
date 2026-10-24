# Portal

Seamless Source-style portal pair. Files: `util/portal.gd`, `util/portal.gdshader`, `util/portal.tscn`.

## Setting one up

Instance `util/portal.tscn` twice, A and B. Set each one's `target` to the other. Size is an export (default 2.5 x 3), and in the editor it shows as a translucent cyan quad so you can line it up with a doorway.

The portal faces local -Z, same as everything else in the project. The -Z side is where you stand to look into it, and you walk from -Z to +Z to go through. So a portal in a wall should have its -Z side facing out into the room. Keep scale at 1 (scale the size export instead). The bottom edge should sit at floor level on both ends, since the player's height relative to the portal is preserved.

## How it works

Each portal builds its own SubViewport and Camera3D at runtime. Every frame the camera is placed at `target * flip180Y * portal^-1 * viewerCamera`, which is the viewer's spot relative to this portal re-expressed relative to the target, turned around. The result is drawn on the quad in screen space. The camera sits behind the target's plane, so its near clip is moved onto that plane to stop the wall around the target from blocking the view.

Teleport is checked every physics tick against the player's camera (not the body, since the camera is what the eye sees). When the camera crosses the portal plane inside the opening, the body is moved through, with its transform and velocity mapped through the same matrix. The swap is exact, at the plane, whichever way you're looking, and it lands you just in front of the target.

The thing that used to make this flicker is the camera's near plane. It's a small rectangle floating in front of the lens, and its corners cross the portal plane before the camera does (sideways, the edge leads by the most), so for a few frames part of the screen showed what's really behind the portal. Swapping early or late depending on the view direction only moved the problem around. Now the portal surface is a box that reaches back from the plane by the distance from the lens to a near-plane corner whenever the camera is close (`_update_screen_depth`). Anything the near plane pokes into is inside the box and shows the portal image like the rest of the surface (the shader has `cull_disabled` so the inside faces draw), and when the swap happens the real world takes over seamlessly. Away from the portal the box collapses back to a flat quad. While walking it flattens the body to yaw only (the controller keeps pitch on the camera); with the jetpack on it keeps the full rotation. It also seeds the target's last-position so you don't bounce straight back.

RigidBody3D props go through too. Each portal has a hidden Area3D volume in front of it (`body_mask` picks which physics layers it scans). A prop whose centre crosses the opening is moved through the physics server with its velocity and spin rotated into the target's frame. Held objects need a small hook in the controller, in `controller_portal_patch.md`: if the line from the camera to the hold point passes through a portal, the object is pulled towards where that point comes out of the other portal (whichever hold point is closer to the object wins, so it walks up to the portal, gets teleported, then keeps following). Portals add themselves to the `portals` group so the controller can find them.

Tone mapping: the portal camera renders a copy of the world environment with linear tone mapping, at 1/`hdr_headroom` exposure, and `portal.gdshader` multiplies the result back up. That way the image is only tone mapped once, by the main view, same as everything else. This needs the current shader file: with an old one the portal comes out darker by exactly `hdr_headroom`. Glow and colour adjustments are off in the copy for the same reason. The copy is rebuilt if the world environment changes, but not if properties of the same Environment are edited at runtime.

Portal quads live on render layer 20 and portal cameras don't draw that layer. That means no recursion, you can't see a portal through a portal.

## Not solved yet

- Near clip is a flat plane perpendicular to the view, not oblique. It's now set to the depth of the nearest corner of the target's opening, which stops it clipping real content when you look at a portal at an angle, but at steep angles a sliver of geometry just behind the target plane can show on the far side. Only matters if there's a wall behind the target. Proper fix is an oblique projection matrix, which Godot's Camera3D doesn't expose, so it'd need a shader trick or a workaround.
- No recursion, see above.
- Props switch sides in one go when their centre crosses the plane. A box that's half through will be cut off at the portal quad and then pop out whole on the other side. Source avoids that by drawing a clone on both sides. Not done here.
- Prop detection only sees bodies for a short distance around the plane (2 m in front, 1 m behind) and compares positions tick to tick, so something moving extremely fast could skip the check. Throw speed (14 m/s) is fine.
- The surface box reaches back about 10 cm behind the portal plane while the camera is close. If a portal is mounted on a wall thinner than that, the back of the box could show from the other side of the wall during those moments. Normal wall thickness is fine.
- Highlights brighter than `hdr_headroom` (default 4x white) clip inside the portal image. Bright emissive panels seen through a portal won't bloom quite like the real ones, because glow is turned off for the portal camera and the main view only sees the clamped value.
- Portals with the opening in a floor or ceiling are untested with the grounded controller.
- Each active portal is a full extra scene render. Culling is only distance and which side you're on right now (`max_render_distance`). Add frustum culling if the ship gets heavy.
- Written without running it in Godot, so none of it has been tested yet.