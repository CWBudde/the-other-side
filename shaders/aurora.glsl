// Auroras by nimitz 2017 (twitter: @stormoid)  https://www.shadertoy.com/view/XtGGRt
// License Creative Commons Attribution-NonCommercial-ShareAlike 3.0 Unported License
// Contact the author for other licensing options
//
// Adapted for "The Other Side": arbitrary step count, heights relative to the
// ray origin, no global `time` macro, helpers renamed to avoid clashes.
//
// Contract: vec4 aurora(vec3 ro, vec3 rd, int steps)
//   -> premultiplied linear rgb + alpha (coverage) for view direction rd.
//
// Changes against the original: the rainbow palette is replaced by a cyan-green
// to teal emission ramp, and the volume density is multiplied by a large-scale
// band mask in the horizontal plane of the layer, so the aurora reads as two
// broad ribbons (main arc plus a second arc from the centre down to the right
// horizon) instead of filling the whole sky. nimitz's final smoothstep is
// replaced by a soft exponential saturation, dense parts turn into a pale mint
// core, and a cheap analytic halo lifts the sky around the arcs.

/*
	There are two main hurdles I encountered rendering this effect.
	First, the nature of the texture that needs to be generated to get a believable effect
	needs to be very specific, with large scale band-like structures, small scale non-smooth variations
	to create the trail-like effect, a method for animating said texture smoothly and finally doing all
	of this cheaply enough to be able to evaluate it several times per fragment/pixel.

	The second obstacle is the need to render a large volume while keeping the computational cost low.
	Since the effect requires the trails to extend way up in the atmosphere to look good, this means
	that the evaluated volume cannot be as constrained as with cloud effects. My solution was to make
	the sample stride increase polynomially, which works very well as long as the trails are lower opcaity than
	the rest of the effect. Which is always the case for auroras.

	After that, there were some issues with getting the correct emission curves and removing banding at lowered
	sample densities, this was fixed by a combination of sample number influenced dithering and slight sample blending.
*/

// ---- tunables -----------------------------------------------------------------
// The band mask is evaluated per volume sample from its position q = (x, z) on
// nimitz's layer, relative to the eye (+z = view direction), in two coordinates:
//   azimuth  phi = atan(q.x, q.y)                (frame edges at about +-0.53 rad)
//   virtual elevation v = (0.8 / |q| - 0.4) / 2  (~ tan(elevation) at which the
//                                                 lowest layer sees q; ~ frame
//                                                 height above the horizon / 1.5)
// Each arc is v = height * (1 - x^2) / (1 + fall * x^2), x = (phi - centre) /
// halfWidth (a parabola for fall = 0), so it meets the horizon at centre +-
// halfWidth; the half width can differ left and right. Higher layers see the same q at a
// larger elevation, which turns the thin arc into curtains rising above it.
// phi is constant along a view ray, so all per-arc terms are set up once per ray.
// Debug: -D AUR_DEBUG=1 with VIEW=2 shows the lowest-layer masks (red = main arc,
// green = second arc); -D AUR_DEBUG_ALPHA=1 with VIEW=2 shows the coverage.
const vec4  AUR_ARC_A      = vec4(0.02, 0.50, 0.178, 0.020); // main arc: centre phi, half width (left), height, sheet half thickness
const vec4  AUR_ARC_B      = vec4(0.0, 0.88, 0.126, 0.016);  // second arc (centre to the right horizon)
const vec2  AUR_SKEW       = vec2(0.95, 0.52);   // right half width / left half width (arc A, arc B)
const vec2  AUR_FALL       = vec2(0.0, 2.8);    // arc shape (A, B): 0 = parabola, > 0 = steep top, long flat run-out
const float AUR_FOOT       = 0.8;               // extra sheet thickness where an arc meets the horizon
const float AUR_ARC_B_GAIN = 1.25;               // second arc: relative brightness
const float AUR_GLOW       = 0.05;              // soft shoulder around the sheets (inside the volume)
const float AUR_HALO       = 0.10;              // wide analytic halo that lifts the sky around the arcs
const float AUR_HALO_W     = 0.22;              // halo width relative to the sheet thickness (smaller = wider)
const float AUR_WOBBLE     = 0.010;             // amplitude of the slow undulation (v units)
const float AUR_DRIFT      = 0.03;              // speed of undulation and brightness drift
const float AUR_TEX_SCALE  = 6.0;               // frequency of nimitz's curtain texture
const float AUR_RAYS       = 0.4;               // 0 = nimitz's world-space texture, 1 = band-aligned rays
const float AUR_RAY_FREQ   = 14.0;              // ray texture frequency along the azimuth
const float AUR_BODY       = 0.15;              // smooth density added under the streaks (tames hot spots)
const float AUR_DENSITY    = 1.3;               // density gain inside the band mask
const float AUR_STRIDE     = 0.0015;            // nimitz's polynomial stride (curtain height)
const float AUR_LEAN       = 0.78;              // 0 = vertical curtains, 1 = flat ribbon on the dome
const float AUR_EXPOSE     = 1.5;               // soft saturation of the integrated emission
const float AUR_TOE        = 1.8;               // > 1 darkens the thin wings (nimitz's smoothstep ~ 2)
const float AUR_HORIZON    = 0.65;              // brightness kept right at the horizon (fade over ~2 deg)
const float AUR_LEFT_BOOST = 1.3;               // extra brightness of the main arc's left arm
const float AUR_INTENSITY  = 0.55;              // overall emission scale
const float AUR_OPACITY    = 0.35;              // alpha scale (stars shine through)
const vec3  AUR_COL_LOW    = vec3(0.05, 1.00, 0.62); // linear emission at the base
const vec3  AUR_COL_HIGH   = vec3(0.02, 0.55, 0.65); // linear emission at the top (teal)
const vec3  AUR_COL_CORE   = vec3(0.45, 0.85, 0.52); // pale emission of the dense core
const vec2  AUR_CORE       = vec2(0.55, 0.95);   // coverage range over which the core turns pale
const vec3  AUR_COL_HALO   = vec3(0.006, 0.16, 0.14); // linear colour of the halo at full strength

// ---- motion -------------------------------------------------------------------
// All motion is smooth in time and bounded in space: the arcs stay where they
// are, only the texture slides through them, the ribbons ripple and bright
// patches travel along them. AUR_MOTION scales every speed and amplitude below
// (time runs AUR_MOTION times faster and amplitudes grow by the same factor);
// 0 gives the old, nearly static aurora.
const float AUR_MOTION     = 0.5;               // master gain of the motion
const vec3  AUR_SLIDE      = vec3(0.3, 0.35, 0.07); // common drift of rays and folds along the arcs: centre (rad),
                                                // swing (rad), rate (rad/s); peak speed 0.025 rad/s, reverses every ~45 s.
                                                // An endless drift would run nimitz's swirl to huge coordinates and smear
                                                // it; offsets below ~-0.2 also turn the texture fibrous, hence the centre.
const vec2  AUR_SLIDE_VAR  = vec2(0.10, 0.06);  // two waves of extra slide (rad) running along the arcs
const vec2  AUR_SLIDE_RATE = vec2(0.26, -0.34); // their rates (rad/s): local speeds differ by up to VAR * RATE
const float AUR_WAVE       = 0.012;             // amplitude of the travelling undulations of the arcs (v units)
const vec2  AUR_WAVE_RATE  = vec2(0.70, 0.90);  // angular frequency of the two wave trains (periods ~9 s and ~7 s)
const vec2  AUR_SURGE      = vec2(0.24, 0.16);  // brightness patches: travel along the arc, change in place (noise cells/s)
const float AUR_SURGE_OCT  = 0.35;              // share of a finer, faster second octave in the brightness patches
const float AUR_SHIMMER    = 0.22;              // rotation speed of nimitz's texture (rays morph; was 0.06)

mat2 aurMm2(float a) { float c = cos(a), s = sin(a); return mat2(c, s, -s, c); }
const mat2 AUR_M2 = mat2(0.95534, 0.29552, -0.29552, 0.95534);
float aurTri(float x) { return clamp(abs(fract(x) - 0.5), 0.01, 0.49); }
vec2 aurTri2(vec2 p) { return vec2(aurTri(p.x) + aurTri(p.y), aurTri(p.y + aurTri(p.x))); }

float triNoise2d(vec2 p, float spd) {
    float z = 1.8;
    float z2 = 2.5;
    float rz = 0.0;
    p *= aurMm2(p.x * 0.06);
    vec2 bp = p;
    for (float i = 0.0; i < 5.0; i++) {
        vec2 dg = aurTri2(bp * 1.85) * 0.75;
        dg *= aurMm2(mod(iTime * spd, TAU)); // wrapped: sin / cos lose precision for large angles
        p -= dg / z2;

        bp *= 1.3;
        z2 *= 0.45;
        z *= 0.42;
        p *= 1.21 + (rz - 1.0) * 0.02;

        rz += aurTri(p.x + aurTri(p.y)) * z;
        p *= -AUR_M2;
    }
    return clamp(1.0 / pow(rz * 29.0, 1.3), 0.0, 0.55);
}

// Per-ray setup of one arc for azimuth phi (constant along a view ray, since
// every sample q is a positive multiple of rd.xz). arc = (centre, left half
// width, height, thickness), skew = right half width / left half width,
// fall = shape: 0 is a parabola, larger values drop faster from the top and
// then run out flat toward the horizon, e = h (1 - x^2) / (1 + fall x^2).
// Returns the arc elevation e and 1 / (thickness measured along v), so the
// per-sample profile is a single exp pair.
// tm = motion time (t * AUR_MOTION), dir = travel direction of the waves (+-1).
void aurArcSetup(float phi, vec4 arc, float skew, float fall, float t, float tm, float dir,
                 out float e, out float invW) {
    float hw = arc.y * (phi > arc.x ? skew : 1.0);
    float x = (phi - arc.x) / hw;
    float d = 1.0 / (1.0 + fall * x * x);
    e = arc.z * (1.0 - x * x) * d;
    float slope = -2.0 * arc.z * x * (1.0 + fall) * d * d / hw;  // de/dphi
    // slow undulation along the arc
    e += AUR_WOBBLE * (0.6 * sin(phi * 9.0 + t * AUR_DRIFT * 2.3) + 0.4 * sin(phi * 17.0 - t * AUR_DRIFT * 1.7 + 1.3));
    // travelling ripples: two wave trains running along the ribbon in direction
    // dir (phase speeds ~0.10 and ~0.075 rad/s, i.e. across the frame in ~10-14 s)
    vec2 ph = vec2(7.0, 12.0) * phi - dir * mod(AUR_WAVE_RATE * tm, TAU) + vec2(0.7, 2.9) * dir;
    float wa = AUR_WAVE * AUR_MOTION;
    e += wa * (0.6 * sin(ph.x) + 0.4 * sin(ph.y));
    slope += wa * (0.6 * 7.0 * cos(ph.x) + 0.4 * 12.0 * cos(ph.y));
    // the ribbon widens where it comes down to the horizon (seen more edge-on)
    float w = arc.w * (1.0 + AUR_FOOT * clamp(1.0 - e / arc.z, 0.0, 1.0));
    // dividing the vertical offset by sqrt(1 + slope^2) approximates the
    // perpendicular distance, so the ribbon keeps its thickness where the arc
    // runs steeply down to the horizon
    invW = 1.0 / (w * sqrt(1.0 + slope * slope));
}

// Sheet core plus a wide soft halo; y = offset in sheet thicknesses.
float aurProfile(float y) {
    float y2 = y * y;
    return exp(-y2) + AUR_GLOW * exp(-y2 * 0.15);
}
const float AUR_CUT = 5.5; // |y| beyond which aurProfile() is negligible

vec4 aurora(vec3 ro, vec3 rd, int steps) {
    if (rd.y <= 0.0) return vec4(0.0);

    // ---- per-ray band setup ------------------------------------------------
    float t = iTime;
    float tm = t * AUR_MOTION;
    float phi = atan(rd.x, rd.z);
    float eA, iwA, eB, iwB;
    aurArcSetup(phi, AUR_ARC_A, AUR_SKEW.x, AUR_FALL.x, t, tm, 1.0, eA, iwA);
    aurArcSetup(phi, AUR_ARC_B, AUR_SKEW.y, AUR_FALL.y, t + 50.0, tm, -1.0, eB, iwB);
    // brightness surges: patches that travel along each arc (A to the right,
    // B to the left) and brighten / fade in place over a few seconds
    float sA = mix(noise(vec2(phi * 4.0 + t * AUR_DRIFT * 0.4 - tm * AUR_SURGE.x, 3.1 + tm * AUR_SURGE.y)),
                   noise(vec2(phi * 9.0 - tm * AUR_SURGE.x * 1.7, 13.7 + tm * AUR_SURGE.y * 1.6)), AUR_SURGE_OCT);
    float sB = mix(noise(vec2(phi * 5.0 - t * AUR_DRIFT * 0.3 + tm * AUR_SURGE.x, 7.3 + tm * AUR_SURGE.y)),
                   noise(vec2(phi * 10.0 + tm * AUR_SURGE.x * 1.7, 21.1 + tm * AUR_SURGE.y * 1.6)), AUR_SURGE_OCT);
    // main arc: strongest on the left and in the centre, fainter to the right
    float gA = mix(0.4, 0.7, smoothstep(0.42, 0.1, phi));
    gA *= 0.55 + 0.45 * sA;
    gA *= 1.0 + AUR_LEFT_BOOST * smoothstep(-0.15, -0.32, phi) * smoothstep(-0.54, -0.38, phi);
    // second arc: starts left of centre and runs down to the right horizon
    float gB = AUR_ARC_B_GAIN * smoothstep(-0.34, -0.18, phi) * mix(0.85, 1.05, smoothstep(0.1, 0.3, phi));
    gB *= 0.55 + 0.45 * sB;
    gB *= mix(1.0, 0.15, smoothstep(0.22, 0.45, phi)); // softer where it meets the right horizon
    if (gB < 1e-3) eB = -1.0; // move a missing arc out of reach
    float vHi = max(eA + AUR_CUT / iwA, eB + AUR_CUT / iwB); // band influence in v
    float vLo = min(eA - AUR_CUT / iwA, eB - AUR_CUT / iwB);

    // Wide analytic halo on the layer-0 elevation v0: lifts the sky around the
    // arcs (no alpha, no texture).
    float hz = length(rd.xz);
    float pt0 = 1.0 / (rd.y * 2.0 + 0.4);
    float v0 = (1.0 / (pt0 * hz) - 0.4) * 0.5;
    vec2 hy = vec2(v0 - eA, v0 - eB) * vec2(iwA, iwB) * AUR_HALO_W;
    vec3 halo = AUR_COL_HALO * AUR_HALO * (gA * exp(-hy.x * hy.x) + gB * exp(-hy.y * hy.y));
    halo *= clamp(rd.y * 20.0 + AUR_HORIZON, 0.0, 1.0);

    // v of a sample: (0.8 / |q| - 0.4) / 2 with |q| = pt * |rd.xz| * lean(lay)
    // whole ray above the band: even the highest layer (smallest v) is above vHi
    float layMax = 0.8 + pow(50.0, 1.4) * AUR_STRIDE;
    float vMin = (0.8 / (layMax * pt0 * hz * pow(0.8 / layMax, AUR_LEAN)) - 0.4) * 0.5;
    if (vMin > vHi) return vec4(halo, 0.0);
#ifdef AUR_DEBUG
    {
        // layer-0 masks of the two arcs (red = main, green = second)
        return vec4(gA * aurProfile((v0 - eA) * iwA), gB * aurProfile((v0 - eB) * iwB), 0.0, 1.0);
    }
#endif

    vec4 col = vec4(0.0);
    vec4 avgCol = vec4(0.0);

    // nimitz used 50 samples; scale the sample index so fewer steps cover the
    // same height range with roughly the same total energy.
    float k = 50.0 / float(steps);
    float dither = hash12(gl_FragCoord.xy);
    vec3 origin = vec3(ro.x, 0.0, ro.z - 6.7); // layer heights are relative to the eye
    // Lateral slide ds of the texture through the (fixed) band mask: a common
    // drift plus a bounded extra slide that varies along the arc, so
    // neighbouring parts move at different speeds without the texture shearing
    // apart over time. The world-space part is moved by the same angle as a
    // sideways shift (x) at the sample's distance, not a turn about the eye: a
    // turn would also change the orientation of nimitz's texture and streak it.
    // ds is constant along the ray. A slide that differs per layer (height) or
    // per arc needs a shear across the layers or across v, which drags the
    // texture into fibres even when small; the arcs differ by their waves and
    // surges instead.
    float spd = mix(0.06, AUR_SHIMMER, AUR_MOTION);
    float drift = AUR_MOTION * (AUR_SLIDE.x + AUR_SLIDE.y * sin(mod(AUR_SLIDE.z * tm, TAU)));
    vec2 slVar = AUR_SLIDE_VAR * AUR_MOTION;
    vec2 slPh = mod(AUR_SLIDE_RATE * tm, TAU) + vec2(2.0, 3.5) * phi + vec2(0.0, 1.7);
    vec2 sl0 = slVar * sin(slPh);
    float ds = drift + sl0.x + sl0.y;
    float phiT = phi + ds;
    float shiftX = hz * ds;

    for (int j = 0; j < steps; j++) {
        float i = (float(j) + dither) * k; // stratified jitter across layers
        float of = 0.006 * k * dither * smoothstep(0.0, 15.0, i);
        float lay = 0.8 + pow(i, 1.4) * AUR_STRIDE;
        float pt = lay * pt0 - of;
        // Higher layers see the band pushed outward (the sheet leans away from
        // the eye), which shortens the curtains into a ribbon on the dome.
        float v = (0.8 / (pt * hz * pow(0.8 / lay, AUR_LEAN)) - 0.4) * 0.5;
        if (v < vLo) break; // v only decreases along the ray: below the band for good
        vec4 col2 = vec4(0.0);
        if (v < vHi) {
            float band = gA * aurProfile((v - eA) * iwA) + gB * aurProfile((v - eB) * iwB);
            // nimitz's world-space texture coordinates (shifted sideways by the
            // slide), blended with band-aligned polar ones (azimuth stretched)
            // for finer rays across the ribbon
            vec2 bzx = origin.zx + pt * vec2(rd.z, rd.x + shiftX);
            vec2 tp = bzx * AUR_TEX_SCALE * (1.0 - AUR_RAYS)
                    + vec2(phiT * AUR_RAY_FREQ, v * AUR_RAY_FREQ * 0.25) * AUR_RAYS;
            float rzt = (AUR_BODY + triNoise2d(tp, spd)) * band * AUR_DENSITY;
            col2 = vec4(mix(AUR_COL_LOW, AUR_COL_HIGH, smoothstep(0.0, 50.0, i)) * rzt, rzt);
        }
        avgCol = mix(avgCol, col2, 0.5);
        col += avgCol * exp2(-i * 0.065 - 2.5) * smoothstep(0.0, 5.0, i) * k;
    }

    col *= clamp(rd.y * 20.0 + AUR_HORIZON, 0.0, 1.0);
    // Soft saturation instead of nimitz's smoothstep: a gentler toe, so the
    // faint wings of the ribbon survive and read as a broad glow.
    col = 1.0 - exp(-pow(col * AUR_EXPOSE, vec4(AUR_TOE)));
#ifdef AUR_DEBUG_ALPHA
    return vec4(vec3(col.a), 1.0);
#endif
    // dense parts of the sheet saturate toward a pale mint core
    float core = smoothstep(AUR_CORE.x, AUR_CORE.y, col.a);
    col.rgb = mix(col.rgb, AUR_COL_CORE * col.a, core);
    return vec4(col.rgb * AUR_INTENSITY + halo, col.a * AUR_OPACITY);
}
