// common.glsl - shared constants, prototypes and helpers.
//
// Colour convention: all shading happens in linear RGB. main.glsl applies the
// tonemap and encodes to sRGB at the very end, so reference hex colours have to
// go through hexColor()/srgbToLinear() before they are used.

#define PI  3.14159265359
#define TAU 6.28318530718

// ---- camera / framing -------------------------------------------------------
const float CAM_HEIGHT = 1.2;   // eye height above the water plane (y = 0)
const float HORIZON    = 0.374; // horizon height as a fraction of the frame, from the bottom
const float FOCAL      = 1.5;   // focal length in frame heights (larger = narrower FOV)

// ---- quality ----------------------------------------------------------------
#ifndef AURORA_STEPS
#define AURORA_STEPS 40         // aurora samples for direct view
#endif
#ifndef AURORA_STEPS_REFL
#define AURORA_STEPS_REFL 12    // aurora samples inside water reflections (dimmed there, so few suffice)
#endif
const float AURORA_REFL_GAIN = 0.3; // aurora strength in water reflections (haze is not scaled)

// Camera position for the current pixel; mainImage sets it before shading.
vec3 gCamPos = vec3(0.0, CAM_HEIGHT, 0.0);

// ---- layer contracts (defined in sky.glsl, aurora.glsl, main.glsl, water.glsl)
vec3 skyBase(vec3 rd);                    // sky gradient + haze + stars, no aurora
vec3 skyBase(vec3 rd, float starGain);    // same with the stars scaled (0 = none)
vec4 aurora(vec3 ro, vec3 rd, int steps); // premultiplied rgb + alpha
vec3 skyFull(vec3 rd);                    // skyBase composited with aurora (AURORA_STEPS)
vec3 skyFull(vec3 rd, int steps);         // same with an explicit aurora step count
vec3 skyRefl(vec3 rd, vec3 rdAur, int steps); // reflection variant, aurora along rdAur, dimmed
vec3 water(vec3 ro, vec3 rd);             // shaded water for a ray with rd.y < 0
vec3 waterNormal(vec2 xz, float dist);    // water surface normal at xz, seen from dist

// ---- math -------------------------------------------------------------------
mat2 rot(float a) {
    float c = cos(a), s = sin(a);
    return mat2(c, s, -s, c);
}

// ---- hashes (Dave Hoskins, "Hash without Sine", MIT) ------------------------
float hash11(float p) {
    p = fract(p * 0.1031);
    p *= p + 33.33;
    p *= p + p;
    return fract(p);
}

float hash12(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

vec2 hash22(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}

vec3 hash33(vec3 p3) {
    p3 = fract(p3 * vec3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yxz + 33.33);
    return fract((p3.xxy + p3.yxx) * p3.zyx);
}

// Integer hash for lattice cells (stable for large coordinates).
vec3 hash33i(ivec3 q) {
    uvec3 p = uvec3(q);
    p = p * uvec3(374761393U, 1103515245U, 668265263U) + p.zxy + p.yzx;
    p = p.yzx * (p.zxy ^ (p >> 3U));
    return vec3(p ^ (p >> 16U)) * (1.0 / float(0xffffffffU));
}

// ---- noise ------------------------------------------------------------------
// Value noise in [0, 1].
float noise(vec2 x) {
    vec2 i = floor(x);
    vec2 f = fract(x);
    vec2 u = f * f * (3.0 - 2.0 * f);
    float a = hash12(i);
    float b = hash12(i + vec2(1.0, 0.0));
    float c = hash12(i + vec2(0.0, 1.0));
    float d = hash12(i + vec2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Fractal value noise in roughly [0, 1].
float fbm(vec2 p, int octaves) {
    float v = 0.0, amp = 0.5, norm = 0.0;
    for (int i = 0; i < octaves; i++) {
        v += amp * noise(p);
        norm += amp;
        p = rot(0.6) * p * 2.03 + 17.1;
        amp *= 0.5;
    }
    return v / norm;
}

// ---- colour -----------------------------------------------------------------
vec3 srgbToLinear(vec3 c) { return pow(c, vec3(2.2)); }
vec3 linearToSrgb(vec3 c) { return pow(max(c, 0.0), vec3(1.0 / 2.2)); }

// hexColor(0x3d8a99) -> linear RGB
vec3 hexColor(int h) {
    return srgbToLinear(vec3((h >> 16) & 255, (h >> 8) & 255, h & 255) / 255.0);
}
