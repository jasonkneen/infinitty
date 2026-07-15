// Metal shaders, compiled at startup. Two instanced pipelines: solid quads
// (backgrounds, cursor, underline/strikethrough) and textured glyph quads
// sampled from the alpha atlas. Whole screen renders in <= 3 draw calls.
let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 viewport;
};

struct BGInstance {
    float2 origin;
    float2 size;
    float4 color;
};

struct GlyphInstance {
    float2 origin;
    float2 size;
    float2 uvOrigin;
    float2 uvSize;
    float4 color;
};

struct VSOut {
    float4 position [[position]];
    float4 color;
    float2 uv;
};

static inline float2 toNDC(float2 p, float2 viewport) {
    float2 ndc = p / viewport * 2.0 - 1.0;
    ndc.y = -ndc.y;
    return ndc;
}

vertex VSOut bg_vertex(uint vid [[vertex_id]],
                       uint iid [[instance_id]],
                       const device BGInstance *inst [[buffer(0)]],
                       constant Uniforms &u [[buffer(1)]]) {
    float2 corner = float2(vid & 1, vid >> 1);
    BGInstance i = inst[iid];
    VSOut out;
    out.position = float4(toNDC(i.origin + corner * i.size, u.viewport), 0.0, 1.0);
    out.color = i.color;
    out.uv = corner;
    return out;
}

fragment float4 bg_fragment(VSOut in [[stage_in]]) {
    return in.color;
}

vertex VSOut glyph_vertex(uint vid [[vertex_id]],
                          uint iid [[instance_id]],
                          const device GlyphInstance *inst [[buffer(0)]],
                          constant Uniforms &u [[buffer(1)]]) {
    float2 corner = float2(vid & 1, vid >> 1);
    GlyphInstance i = inst[iid];
    VSOut out;
    out.position = float4(toNDC(i.origin + corner * i.size, u.viewport), 0.0, 1.0);
    out.color = i.color;
    out.uv = i.uvOrigin + corner * i.uvSize;
    return out;
}

fragment float4 glyph_fragment(VSOut in [[stage_in]],
                               texture2d<float> atlas [[texture(0)]]) {
    constexpr sampler s(coord::normalized, filter::nearest);
    float a = atlas.sample(s, in.uv).r;
    return float4(in.color.rgb, in.color.a * a);
}

// RGBA sprites (codex pets). Texture is premultiplied (CoreGraphics).
fragment float4 sprite_fragment(VSOut in [[stage_in]],
                                texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(coord::normalized, filter::nearest);
    return tex.sample(s, in.uv);
}
"""
