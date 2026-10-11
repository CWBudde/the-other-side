// meteors.glsl - fast shooting stars crossing the upper sky.
//
// Contract: vec3 meteors(vec3 rd) -> additive linear RGB for view direction rd.
//
// Time is cut into slots of METEOR_SLOT seconds. Hashes of the slot decide
// whether it has a meteor (METEOR_PROB), when it starts, its start and end
// point, life, fade-out and brightness. The current and the previous slot are
// evaluated, so a meteor crossing a slot boundary is not cut off.
// Every meteor crosses the whole frame from right to left, descending gently
// (screen dy/dx ~0.13..0.17): it starts at or just beyond the right edge high
// up and ends near the left edge, never below METEOR_Y_MIN of the frame
// height (the horizon is at 0.374). The end points are given in frame
// fractions of a 16:9 frame at zero yaw and turned into world directions, so
// the path is a great-circle arc fixed to the sky: it ignores the camera yaw
// drift, draws as a straight line and keeps its proportions at any
// resolution. The line is a Gaussian across the path with a pixel-footprint
// floor, like the stars in sky.glsl: a bright head and an exponentially
// fading tail whose length grows with the speed.
//
// Loop mode (LOOP > 0, common.glsl): the slot length is adjusted so a whole
// number of slots fills the loop, and the slot index wraps once per loop, so
// a meteor crossing the loop point continues after it. METEOR_SEED picks
// another set of meteors.
//
// Shots: -D METEOR_FORCE=1 gives every slot a meteor whose head is at mid
// frame, at full brightness, at t = k * METEOR_SLOT + 0.7 (k = 0, 1, 2, ...).

#ifndef METEOR_FORCE
#define METEOR_FORCE 0
#endif
#ifndef METEOR_SEED
#define METEOR_SEED 0
#endif

// ---- tunables ---------------------------------------------------------------
// Positions are fractions of a 16:9 frame (x from the left, y from the bottom).
const float METEOR_SLOT      = 4.0;              // seconds per slot
const float METEOR_PROB      = 0.5;              // chance of a meteor per slot (one per ~8 s)
const vec2  METEOR_X0        = vec2(0.88, 1.05); // start x (at or beyond the right edge)
const vec2  METEOR_Y0        = vec2(0.92, 1.02); // start y (high enough that SLOPE.y never hits the floor)
const vec2  METEOR_X1        = vec2(-0.05, 0.12); // end x (near the left edge)
const vec2  METEOR_SLOPE     = vec2(0.13, 0.17); // screen dy/dx (~7-10 deg), capped so the end stays above Y_MIN
const float METEOR_Y_MIN     = 0.57;             // lowest end point
const vec2  METEOR_LIFE      = vec2(0.6, 1.2);   // seconds for the whole crossing (~50..95 deg/s)
const float METEOR_RISE      = 0.08;             // fade-in, fraction of the life
const vec2  METEOR_FADE      = vec2(0.6, 0.95);  // fade-out starts here (fraction of the life) ...
const float METEOR_FADE_LEN  = 0.3;              // ... and takes this long (cut off at the end)
const float METEOR_PEAK      = 1.5;              // linear head brightness of the brightest meteor (1080p)
const float METEOR_TAIL_GAIN = 0.4;              // tail brightness relative to the head
const float METEOR_TAIL      = 0.025;            // tail e-folding length in seconds of travel
const float METEOR_WIDTH     = 1.5e-4;           // intrinsic angular sigma of the line (radians)
const float METEOR_AA        = 0.5;              // minimum sigma in pixels (antialiasing footprint)
const float METEOR_HEAD_W    = 1.7;              // head sigma relative to the line sigma
const vec3  METEOR_HEAD_COL  = vec3(1.0, 1.0, 0.97);   // near-white head
const vec3  METEOR_TAIL_COL  = vec3(0.78, 0.9, 1.0);   // cool blue-white tail ...
const vec3  METEOR_END_COL   = vec3(0.62, 0.95, 0.86); // ... with a hint of green toward its end

// World direction of a 16:9 frame point (x, y in frame fractions) at zero yaw.
vec3 meteorDir(vec2 f) {
    return normalize(vec3((f.x - 0.5) * (16.0 / 9.0), f.y - HORIZON, FOCAL));
}

vec3 meteors(vec3 rd) {
    // Pixel-footprint width; the peak is scaled so the flux across the line
    // stays at its 1080p value.
    float pa = 1.0 / (iResolution.y * FOCAL);
    float w2 = METEOR_WIDTH * METEOR_WIDTH;
    float sig = sqrt(w2 + (METEOR_AA * pa) * (METEOR_AA * pa));
    float ref = sqrt(w2 + pow(METEOR_AA / (1080.0 * FOCAL), 2.0));
    float sigH = sig * METEOR_HEAD_W;

    vec3 col = vec3(0.0);
#if LOOP > 0
    int slots = max(int(floor(LOOP_T / METEOR_SLOT + 0.5)), 1); // not round(): x.5 rounds either way
    float slotLen = LOOP_T / float(slots);
#else
    float slotLen = METEOR_SLOT;
#endif
    float time = sceneTime();
    float slot0 = floor(time / slotLen);
    for (int i = 0; i < 2; i++) {
        float slot = slot0 - float(i);
#if LOOP > 0
        int id = (int(slot) + slots) % slots; // the slot before the first is the last one
#else
        int id = int(slot);
#endif
        vec3 h = hash33i(ivec3(id, 4507 + METEOR_SEED, 21));
        vec3 k = hash33i(ivec3(id, 4507 + METEOR_SEED, 22));
        vec3 m = hash33i(ivec3(id, 4507 + METEOR_SEED, 23));
        float life = mix(METEOR_LIFE.x, METEOR_LIFE.y, m.y);
#if METEOR_FORCE
        float t0 = slot * slotLen + 0.7 - 0.45 * life; // u = 0.45: head at mid frame
#else
        if (h.x > METEOR_PROB) continue;
        float t0 = slot * slotLen + slotLen * h.y;
#endif
        float u = (time - t0) / life; // 0..1 over the crossing
        if (u <= 0.0 || u >= 1.0) continue;

        // End points: the slope is capped so the end stays above Y_MIN.
        vec2 f0 = vec2(mix(METEOR_X0.x, METEOR_X0.y, k.x), mix(METEOR_Y0.x, METEOR_Y0.y, k.y));
        float x1 = mix(METEOR_X1.x, METEOR_X1.y, k.z);
        float dx = abs(x1 - f0.x) * (16.0 / 9.0); // in frame heights, like dy
        float slope = mix(METEOR_SLOPE.x, min(METEOR_SLOPE.y, (f0.y - METEOR_Y_MIN) / dx), m.x);
        vec3 p0 = meteorDir(f0);
        vec3 p1 = meteorDir(vec2(x1, f0.y - slope * dx));

        // Great circle p0 -> p1 with tangent t; x = distance across the path,
        // s = arc length along it.
        float c = dot(p0, p1);
        vec3 t = normalize(p1 - c * p0);
        float x = dot(rd, cross(p0, t));
        if (abs(x) > 6.0 * sigH) continue;
        float len = acos(c);
        float tl = METEOR_TAIL * (len / life) * mix(0.8, 1.2, m.z);
        float s = atan(dot(rd, t), dot(rd, p0));
        float d = len * u * (1.1 - 0.1 * u) - s; // behind the slightly slowing head
        if (d < -6.0 * sigH || d > 8.0 * tl) continue;

        float fade = mix(METEOR_FADE.x, METEOR_FADE.y, h.z);
        float env = smoothstep(0.0, METEOR_RISE, u)
                  * (1.0 - smoothstep(fade, min(fade + METEOR_FADE_LEN, 1.0), u))
                  * mix(0.8, 1.0, smoothstep(0.0, 0.5, u)); // brightens a little
        float bri = METEOR_PEAK * mix(0.45, 1.0, hash12(vec2(float(id), 4507.0 + float(METEOR_SEED)))) * env * (ref / sig);
        float head = exp(-(d * d + x * x) / (2.0 * sigH * sigH));
        float tail = exp(-x * x / (2.0 * sig * sig) - max(d, 0.0) / tl)
                   * smoothstep(-sig, sig, d) * smoothstep(0.0, 0.5 * tl, s);
        float f = 1.0 - exp(-max(d, 0.0) / tl);
        vec3 tc = mix(METEOR_TAIL_COL, METEOR_END_COL, f * f);
        col += bri * (METEOR_HEAD_COL * head + tc * (METEOR_TAIL_GAIN * tail));
    }
    return col;
}
