// water.glsl - calm night sea.
//
// Contracts:
//   vec3 water(vec3 ro, vec3 rd)            -> linear RGB, caller guarantees rd.y < 0
//   vec3 waterNormal(vec2 xz, float dist)   -> unit normal (used by VIEW 4)
// Reflections call skyRefl(dir, dirAurora, AURORA_STEPS_REFL), defined in main.glsl,
// and boatCover (boat.glsl) for the reflection of the boat.
//
// Approach: analytic ray/plane hit at y = 0 (no raymarching). The surface is a
// height field whose gradient is evaluated analytically:
//   - WATER_SWELLS directional sines with long wavelengths, travelling roughly
//     towards the camera, so their crests run along x and read as soft
//     horizontal bands. A shared low-frequency warp bends the crests slightly.
//   - WATER_RIPPLE_OCTAVES octaves of gradient noise, stretched along x, for the
//     fine elongated ripples and highlight streaks.
// Every component is pre-filtered against the pixel footprint (anisotropic:
// the footprint is stretched along the view direction by 1/sin(grazing)), so
// detail fades out smoothly toward the horizon instead of aliasing. The slope
// variance that got filtered away is kept and used as sub-pixel roughness:
// at grazing angles only the facets tilted toward the viewer are visible, so
// the effective normal is tilted toward the camera, which lowers the fresnel
// and reflects slightly higher (darker) sky. That gives the crisp horizon line
// with the water a bit darker than the sky right above it.

// ---- tunables ---------------------------------------------------------------
// Swells (long directional waves)
#define WATER_SWELLS 6
const float WATER_SWELL_LAMBDA = 14.0;  // longest wavelength in metres
const float WATER_SWELL_DECAY  = 0.68;  // wavelength ratio between successive swells
const float WATER_SWELL_SLOPE  = 0.09;  // peak slope (a*k) of the first swell
const float WATER_SWELL_SLOPE_DECAY = 0.85; // slope ratio between successive swells
const float WATER_SWELL_SPREAD = 0.6;  // direction spread around the view axis (radians)
const float WATER_SWELL_ANGLE  = 0.12;  // mean direction offset from the view axis (radians)
const float WATER_WARP_SCALE   = 0.05;  // frequency of the crest-bending warp (1/m)
const float WATER_WARP_AMOUNT  = 2.2;   // warp strength in radians of phase
const float WATER_SWELL_SHARP  = 1.4;   // crest sharpening (0 = sine): narrow crests, broad troughs

// Ripples (noise octaves, stretched along x)
#define WATER_RIPPLE_OCTAVES 2
const vec2  WATER_RIPPLE_FREQ  = vec2(0.32, 1.0); // noise cycles per metre (x, z) of octave 0
const float WATER_RIPPLE_AMP   = 0.014;          // height amplitude of octave 0 in metres
const float WATER_RIPPLE_GAIN  = 0.45;           // amplitude ratio between octaves
const float WATER_RIPPLE_LACUN = 2.3;            // frequency ratio between octaves
const float WATER_RIPPLE_REFL  = 0.5;            // how much ripples steer the reflection ray (1 = fully)
const vec2  WATER_RIPPLE_DRIFT = vec2(0.03, -0.25); // drift speed (m/s) of octave 0

// Animation
const float WATER_TIME_SCALE   = 0.55; // slows the deep-water dispersion (calm sea)

// Anti-aliasing / roughness
const float WATER_AA           = 0.6;  // Gaussian filter width in pixel footprints
const float WATER_MASK_TILT    = 1.2;  // horizon tilt of the visible facets per unit slope rms
const float WATER_MASK_REACH   = 1.0;  // masking fades out at sin(grazing) ~ REACH * slope rms
const float WATER_ROUGH_LOSS   = 30.0; // reflection loss per unit filtered slope variance

// Shading
const vec3  WATER_BODY         = vec3(0.000, 0.047, 0.103); // upwelling deep-water colour (linear)
const vec3  WATER_TINT         = vec3(0.03, 0.95, 1.05);     // tint of the reflected sky (keeps the sea blue)
const float WATER_TINT_DIST    = 150.0; // distance scale (m) over which the tint fades out toward the horizon
const float WATER_F0           = 0.02;  // Schlick reflectance at normal incidence
const float WATER_REFL_GAIN    = 0.85;  // overall reflection intensity
const float WATER_AUR_FLATTEN  = 0.5;   // aurora reflection uses a normal this much flatter (smoother, less patchy)
const float WATER_NEAR_DARK    = 0.0;   // extra darkening of the reflection in the foreground
const float WATER_NEAR_DIST    = 6.0;   // distance (m) where the foreground darkening ends

// ---- helpers ----------------------------------------------------------------

// Gradient noise with analytic derivatives (after Inigo Quilez, MIT).
// Returns (value in about [-0.7, 0.7], d/dx, d/dy).
vec3 waterNoised(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u  = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    vec2 du = 30.0 * f * f * (f * (f - 2.0) + 1.0);

    vec2 ga = hash22(i) * 2.0 - 1.0;
    vec2 gb = hash22(i + vec2(1.0, 0.0)) * 2.0 - 1.0;
    vec2 gc = hash22(i + vec2(0.0, 1.0)) * 2.0 - 1.0;
    vec2 gd = hash22(i + vec2(1.0, 1.0)) * 2.0 - 1.0;

    float va = dot(ga, f);
    float vb = dot(gb, f - vec2(1.0, 0.0));
    float vc = dot(gc, f - vec2(0.0, 1.0));
    float vd = dot(gd, f - vec2(1.0, 1.0));

    float k = va - vb - vc + vd;
    float v = va + u.x * (vb - va) + u.y * (vc - va) + u.x * u.y * k;
    vec2 d = ga + u.x * (gb - ga) + u.y * (gc - ga) + u.x * u.y * (ga - gb - gc + gd)
           + du * (u.yx * k + vec2(vb, vc) - va);
    return vec3(v, d);
}

// Gaussian pre-filter of a sinusoid with wave vector kv (radians per metre)
// against the anisotropic pixel footprint. v = horizontal view direction,
// fp = (footprint across, footprint along the view direction) in metres.
float waterFilter(vec2 kv, vec2 v, vec2 fp) {
    float kAlong  = dot(kv, v);
    float kAcross = kv.x * v.y - kv.y * v.x;
    vec2 s = vec2(kAcross, kAlong) * fp * WATER_AA;
    return exp(-0.5 * dot(s, s));
}

// Height-field gradient at xz (.xy) plus the slope variance removed by
// filtering (.z) and the total slope variance of the spectrum (.w).
// gRipple receives the ripple part of the gradient on its own.
vec4 waterGradient(vec2 xz, float dist, out vec2 gRipple) {
    float t = iTime * WATER_TIME_SCALE;

    // Pixel footprint on the water plane.
    float fpAcross = dist / (FOCAL * iResolution.y);
    float sinGraze = clamp(gCamPos.y / max(dist, 1e-3), 1e-3, 1.0);
    vec2 fp = vec2(fpAcross, fpAcross / sinGraze);
    vec2 toP = xz - gCamPos.xz;
    vec2 v = toP / max(length(toP), 1e-4);

    vec2 grad = vec2(0.0);
    float varLost = 0.0;
    float varAll = 0.0;

    // Low-frequency warp that bends the swell crests (shared by all swells).
    vec3 w = waterNoised(xz * WATER_WARP_SCALE + vec2(0.0, t * 0.01));
    float warp = WATER_WARP_AMOUNT * w.x;
    vec2 dWarp = WATER_WARP_AMOUNT * WATER_WARP_SCALE * w.yz;

    // Directional swells.
    float lambda = WATER_SWELL_LAMBDA;
    float slope = WATER_SWELL_SLOPE;
    for (int i = 0; i < WATER_SWELLS; i++) {
        float fi = float(i);
        float ang = WATER_SWELL_ANGLE + (hash11(fi * 7.31 + 1.7) - 0.5) * 2.0 * WATER_SWELL_SPREAD;
        vec2 dir = vec2(sin(ang), -cos(ang)); // travel toward the camera (-z)
        float k = TAU / lambda;
        float omega = sqrt(9.81 * k);
        vec2 kv = dir * k;
        // Warp scales with wavelength so short swells are not over-bent.
        float ph = dot(kv, xz) - omega * t + hash11(fi * 3.17 + 0.3) * TAU + warp * (lambda / WATER_SWELL_LAMBDA + 0.3);
        vec2 dph = kv + dWarp * (lambda / WATER_SWELL_LAMBDA + 0.3);
        float att = waterFilter(dph, v, fp);
        float a = slope / k; // height amplitude
        // Sharpened profile h ~ a * exp(Q*(sin(ph)-1)): narrow bright crests,
        // broad flat troughs. Q = 0 gives a plain sine.
        float shape = exp(WATER_SWELL_SHARP * (sin(ph) - 1.0));
        grad += att * a * cos(ph) * shape * dph;
        // Mean-square slope of the sharpened profile: 0.5 for a sine, ~0.07 at Q = 1.4.
        float var = 0.5 * exp(-1.39 * WATER_SWELL_SHARP) * slope * slope;
        varAll += var;
        varLost += var * (1.0 - att * att);
        lambda *= WATER_SWELL_DECAY;
        slope *= WATER_SWELL_SLOPE_DECAY;
    }

    // Ripple octaves: gradient noise, stretched along x, slowly drifting.
    vec2 freq = WATER_RIPPLE_FREQ;
    float amp = WATER_RIPPLE_AMP;
    vec2 drift = WATER_RIPPLE_DRIFT;
    mat2 r = mat2(1.0);
    gRipple = vec2(0.0);
    for (int i = 0; i < WATER_RIPPLE_OCTAVES; i++) {
        // noise coordinate q = freq * (R * xz) + offset ; dq/dxz = diag(freq) * R
        vec2 rxz = r * xz;
        vec3 n = waterNoised(rxz * freq + drift * freq * t + float(i) * 31.7);
        vec2 gq = n.yz * freq;          // gradient w.r.t. the rotated coords
        vec2 g = gq * r;                // back to world: R^T * gq
        // Representative wave vector of this octave: about pi rad per noise cell.
        vec2 kv = (vec2(freq.x, freq.y) * PI) * r;
        float att = waterFilter(kv, v, fp);
        gRipple += att * amp * g;
        // Gradient-noise derivatives have an rms of roughly 0.6 per axis.
        float var = 0.36 * amp * amp * dot(freq, freq);
        varAll += var;
        varLost += var * (1.0 - att * att);
        freq *= WATER_RIPPLE_LACUN;
        amp *= WATER_RIPPLE_GAIN;
        drift *= 0.6;
        r = r * rot(0.35);
    }

    return vec4(grad + gRipple, varLost, varAll);
}

vec3 waterNormal(vec2 xz, float dist) {
    vec2 gRipple;
    vec2 g = waterGradient(xz, dist, gRipple).xy;
    return normalize(vec3(-g.x, 1.0, -g.y));
}

vec3 water(vec3 ro, vec3 rd) {
    float t = -ro.y / min(rd.y, -1e-4);
    vec3 p = ro + t * rd;
    vec2 gRipple;
    vec4 gv = waterGradient(p.xz, t, gRipple);
    // Ripples only partly steer the reflection ray: this stands in for the
    // glossy blur of a micro-rough surface and keeps the aurora reflection
    // from breaking into busy small patches. Fresnel uses the full normal.
    vec2 gRefl = gv.xy - (1.0 - WATER_RIPPLE_REFL) * gRipple;
    vec3 n = normalize(vec3(-gRefl.x, 1.0, -gRefl.y));
    vec3 nFull = normalize(vec3(-gv.x, 1.0, -gv.y));

    // Masking: at grazing angles the back sides of the waves are hidden, so
    // the visible facets are biased toward the viewer. Tilt the normal toward
    // the camera by the slope rms, fading in as the grazing angle drops to the
    // order of the slope rms (negligible in the foreground).
    float sigma = sqrt(gv.w);
    float sinGraze = -rd.y;
    float mask = WATER_MASK_TILT * sigma * exp(-sinGraze / (WATER_MASK_REACH * sigma));
    vec2 toCam = -normalize(rd.xz + 1e-6);
    n = normalize(n + vec3(toCam.x, 0.0, toCam.y) * mask);
    nFull = normalize(nFull + vec3(toCam.x, 0.0, toCam.y) * mask);

    vec3 r = reflect(rd, n);
    r.y = abs(r.y); // rays reflected into the water hit the next wave's back: reuse the sky
    float cosI = max(dot(nFull, -rd), 0.0);
    float fres = WATER_F0 + (1.0 - WATER_F0) * pow(1.0 - cosI, 5.0);
    // Filtered roughness spreads the reflection lobe and loses a little energy.
    fres /= 1.0 + WATER_ROUGH_LOSS * gv.z;

    // Darker foreground: less reflected sky directly in front of the camera.
    float near = 1.0 - WATER_NEAR_DARK * (1.0 - smoothstep(0.0, WATER_NEAR_DIST, t));

    // The aurora is reflected along a flatter normal: broad soft lift instead
    // of bright patches where the swells tilt the ray into the arc.
    vec3 rA = reflect(rd, normalize(mix(n, vec3(0.0, 1.0, 0.0), WATER_AUR_FLATTEN)));
    rA.y = abs(rA.y);
    // The tint (red absorption, the teal grade of the reference) fades out in
    // the far field, so the thin mirror band at the horizon keeps the grey of
    // the haze while everything closer reflects a blue-green sky.
    float far = 1.0 - exp(-t / WATER_TINT_DIST);
    vec3 tint = mix(WATER_TINT, vec3(1.0), far * far);
    vec3 refl = skyRefl(r, rA, AURORA_STEPS_REFL) * tint * WATER_REFL_GAIN * near;
    // The boat in the water: its reflection follows the wavy normal, so it
    // breaks up on the swells. The edge width covers the camera-to-surface
    // part of the path as well.
    float pa = 1.0 / (iResolution.y * FOCAL), tb;
    float boat = boatCover(p, r, pa, t * pa + BOAT_REFL_BLUR, tb);
    refl = mix(refl, BOAT_COL, boat);
    return mix(WATER_BODY, refl, fres);
}
