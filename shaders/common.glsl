// common.glsl - shared constants, prototypes and helpers.
//
// Colour convention: all shading happens in linear RGB. main.glsl applies the
// tonemap and encodes to sRGB at the very end, so reference hex colours have to
// go through hexColor()/srgbToLinear() before they are used.

#define PI  3.14159265359
#define TAU 6.28318530718

// ---- camera / framing -------------------------------------------------------
// HORIZON and FOCAL can be overridden (-D HORIZON_Y=..., -D FOCAL_LEN=...) for
// other aspect ratios: a square frame keeps the horizontal field of view of
// the 16:9 one with FOCAL_LEN = 1.5 * 9 / 16.
#ifndef HORIZON_Y
#define HORIZON_Y 0.374
#endif
#ifndef FOCAL_LEN
#define FOCAL_LEN 1.5
#endif
const float CAM_HEIGHT = 1.2;       // eye height above the water plane (y = 0)
const float HORIZON    = HORIZON_Y; // horizon height as a fraction of the frame, from the bottom
const float FOCAL      = FOCAL_LEN; // focal length in frame heights (larger = narrower FOV)

// ---- loop mode --------------------------------------------------------------
// -D LOOP=n (whole seconds) makes the animation repeat exactly every n seconds,
// for a seamless looping clip. Every motion is adjusted to the loop:
//   - oscillations turn a whole number of cycles per loop (loopRate); the very
//     slow ones (under half a cycle) stand still
//   - drifting noise is sampled at t and t - LOOP and cross-faded (loopMix,
//     loopNorm): both copies drift at the same speed, so the blend still reads
//     as one drifting field, and at the loop point it is back to the start
//   - time-lattice noise (star twinkle) and the meteor slots wrap their
//     integer index once per loop
// LOOP = 0 (default) leaves the free-running animation untouched.
#ifndef LOOP
#define LOOP 0
#endif
const float LOOP_T = float(LOOP);

// Animation time: iTime, wrapped into [0, LOOP) in loop mode.
float sceneTime() {
#if LOOP > 0
    return mod(iTime, LOOP_T);
#else
    return iTime;
#endif
}

// Angular rate w (rad/s), in loop mode rounded to a whole number of cycles
// per loop, so that sin(w * sceneTime()) repeats with the loop.
float loopRate(float w) {
#if LOOP > 0
    return round(w * LOOP_T / TAU) * TAU / LOOP_T;
#else
    return w;
#endif
}
vec2 loopRate(vec2 w) { return vec2(loopRate(w.x), loopRate(w.y)); }

// Cross-fade weight of the copy sampled at sceneTime() - LOOP: 0 at the start
// of the loop, 1 at its end, with zero slope at both ends so the speed does
// not jump at the loop point.
float loopMix() { return smoothstep(0.0, LOOP_T, sceneTime()); }
// Gain that keeps the contrast of a blend of two independent zero-mean noise
// samples, (1 - a) n1 + a n2, at that of a single one.
float loopNorm(float a) { return inversesqrt((1.0 - a) * (1.0 - a) + a * a); }

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

// ---- layer contracts (defined in sky.glsl, aurora.glsl, main.glsl, water.glsl, boat.glsl)
vec3 skyBase(vec3 rd);                    // sky gradient + haze + stars, no aurora
vec3 skyBase(vec3 rd, float starGain);    // same with the stars scaled (0 = none), not dimmed
vec4 aurora(vec3 ro, vec3 rd, int steps); // premultiplied rgb + alpha
vec3 skyFull(vec3 rd);                    // skyBase composited with aurora (AURORA_STEPS)
vec3 skyFull(vec3 rd, int steps);         // same with an explicit aurora step count
vec3 skyRefl(vec3 rd, vec3 rdAur, int steps); // reflection variant, aurora along rdAur, dimmed
vec3 water(vec3 ro, vec3 rd);             // shaded water for a ray with rd.y < 0
vec3 waterNormal(vec2 xz, float dist);    // water surface normal at xz, seen from dist
float waterSwellHeight(vec2 xz);          // unfiltered swell height (m), what the boat floats on
vec4 boat(vec3 ro, vec3 rd, float footprint, float soft, out float t); // boat colour + coverage along a ray
float boatSeaHeight(vec2 xz);             // sea height for the water shading near the boat (0 elsewhere)

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
