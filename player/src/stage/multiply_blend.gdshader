// Exact D3D multiply blend (E-mote bm=3).
//
// The original pipeline is (ADD, SRCBLEND=DESTCOLOR, DESTBLEND=INVSRCALPHA):
//
//     out.rgb = src.rgb * dst.rgb + dst.rgb * (1 - srcA)
//     out.a   = dst.a                                (alpha triple: ZERO/ONE)
//
// Godot's CanvasItemMaterial.BLEND_MODE_MUL is (DST_COLOR, ZERO), which
// drops the dst*(1-srcA) term — an eye-shadow layer textured black with
// alpha shaping then paints a solid black rectangle (regression caught by
// the shot_bm3 A/B on 2026-10-30).
//
// blend_mul multiplies whatever the fragment outputs by dst, so the exact
// result is recovered by feeding it the combined multiplier:
//
//     src' = src.rgb + (1 - srcA)      ->      out = dst * src'
//
// With modulate folded in (canvas COLOR already carries it), c.a is the
// final source alpha and c.rgb the final source color.
shader_type canvas_item;
render_mode blend_mul;

void fragment() {
	vec4 c = texture(TEXTURE, UV) * COLOR;
	COLOR = vec4(c.rgb + (1.0 - c.a), c.a);
}
