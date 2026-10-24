shader_type spatial;
// cull_disabled: when the player's camera is right up against the portal, the near plane
// can end up inside the portal surface box, and then we are looking at its inside faces.
render_mode unshaded, fog_disabled, cull_disabled;

// The portal's SubViewport renders the world from the linked portal's point of view
// at the same size as the main window, so we sample it in screen space.
// The view is rendered at 1/headroom brightness with linear tone mapping (see
// portal.gd), so multiplying by headroom restores scene-linear colour. The main view's
// own tone mapping then treats the portal like any other surface.
uniform sampler2D view_tex : source_color, filter_linear, repeat_disable;
uniform float headroom = 1.0;

void fragment() {
	ALBEDO = texture(view_tex, SCREEN_UV).rgb * headroom;
}
