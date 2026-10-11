// The Other Side - night sea under an aurora: the Image pass.
//
// iChannel0 = Buffer A (buffer_a.glsl, the scene in linear RGB), filter
// mipmap, wrap clamp. This pass softens the frame with a glow: a blurred copy
// of the scene, built from the buffer's mip chain, is blended back in. It
// acts like the veiling glare of a real lens: the bright sky and water bleed
// a little over dark edges (light wrap around the boat), highlights get a
// soft halo and the contrast drops slightly. Then tonemap, vignette, sRGB and
// grain. VIEW (see buffer_a.glsl) is passed through; VIEW 4 shows the buffer
// as is.
#ifndef VIEW
#define VIEW 0
#endif

#ifndef EXPOSURE
#define EXPOSURE 1.0
#endif

#include "common.glsl"

// ---- tunables ---------------------------------------------------------------
#ifndef GLOW_MIX
#define GLOW_MIX 0.3             // share of the blurred copy in the final image (0 = off)
#endif
const float GLOW_FIRST   = 1.0;  // finest mip level at 720p (2^lod pixels wide), scaled with the resolution
const int   GLOW_LEVELS  = 6;    // mip levels summed, each twice as wide as the last
const float GLOW_FALLOFF = 0.6;  // weight ratio between successive levels (lower = tighter glow)

// One mip level, sampled at four half-texel offsets so the coarse levels do
// not show their blocks.
vec3 glowLevel(vec2 uv, float lod) {
    vec2 px = exp2(lod) / iResolution.xy;
    return 0.25 * (textureLod(iChannel0, uv + vec2( 0.5,  0.5) * px, lod).rgb
                 + textureLod(iChannel0, uv + vec2(-0.5,  0.5) * px, lod).rgb
                 + textureLod(iChannel0, uv + vec2( 0.5, -0.5) * px, lod).rgb
                 + textureLod(iChannel0, uv + vec2(-0.5, -0.5) * px, lod).rgb);
}

// The blurred copy: mip levels from GLOW_FIRST up, falling off with width.
vec3 glow(vec2 uv) {
    float lod = GLOW_FIRST + log2(iResolution.y / 720.0);
    vec3 acc = vec3(0.0);
    float wsum = 0.0, w = 1.0;
    for (int i = 0; i < GLOW_LEVELS; i++) {
        acc += w * glowLevel(uv, lod + float(i));
        wsum += w;
        w *= GLOW_FALLOFF;
    }
    return acc / wsum;
}

// Linear in, sRGB out: soft-shoulder tonemap, vignette, grain.
vec3 post(vec3 col, vec2 fragCoord) {
    col *= EXPOSURE;
    vec3 shoulder = 0.6 + 0.4 * (1.0 - exp(-(max(col, 0.6) - 0.6) / 0.4));
    col = mix(col, shoulder, step(0.6, col));

    vec2 q = fragCoord / iResolution.xy;
    col *= mix(0.78, 1.0, pow(16.0 * q.x * q.y * (1.0 - q.x) * (1.0 - q.y), 0.25));

    col = linearToSrgb(col);
    col += (hash12(fragCoord + fract(iTime * 7.13) * 371.0) - 0.5) * (3.0 / 255.0);
    return col;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec3 col = texelFetch(iChannel0, ivec2(fragCoord), 0).rgb;
#if VIEW == 4
    fragColor = vec4(col, 1.0);
#else
    col = mix(col, glow(fragCoord / iResolution.xy), GLOW_MIX);
    fragColor = vec4(post(col, fragCoord), 1.0);
#endif
}
