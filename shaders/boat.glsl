// boat.glsl - an empty rowing boat with its oars resting in the rowlocks, seen
// against the light.
//
// Contracts:
//   vec4 boat(vec3 ro, vec3 rd, float footprint, float soft, out float t)
//     -> rgb = linear colour of the boat along the ray, a = antialiased
//        coverage (0..1); t = ray distance to the boat (only meaningful when
//        a > 0). The edge width is t * footprint + soft (footprint = pixel
//        angle, soft = extra blur in metres, used by the water reflection).
//   float boatSeaHeight(vec2 xz)
//     -> height of the sea surface the water shading should use at xz: the
//        true swell height around the boat, fading to the flat plane (0)
//        within BOAT_SEA_REACH, and 0 (without sampling the swell) beyond.
//
// The boat is a small 3D distance field, sphere-traced only inside its
// bounding box: a plain dinghy with a sheer that springs up toward a raked
// stem, a flat raked transom, flared U sections and an open interior (thin
// walls), a rub rail under the gunwale and a pair of rowlocks amidships. Seen
// from 1.2 m it is almost side-on, but the bow shows its perspective, the far
// gunwale peeks over the near one and the rowlocks stand up as small forks. A
// pair of oars rests in the rowlocks, both swung forward (the far one almost
// along the hull, so the two handles rise side by side over the gunwale), the
// near blade lying on the water off the bow.
//
// Physics, kept cheap:
//   - It floats on the swells: heave, pitch and roll follow the swell height
//     (waterSwellHeight, water.glsl) sampled under the bow, stern, both sides
//     and amidships.
//   - The sea is drawn as a flat plane, but the boat is cut off at the true
//     swell height, so its waterline rises and falls with the passing swells.
//     Around the boat the water shading meets the camera ray at that height
//     too (boatSeaHeight), so the reflection starts at the same waterline and
//     hull and reflection meet.
//   - There is no direct light. The hull is lit by the sky overhead, the
//     bright horizon and aurora beyond it and the sea below, with dark paint,
//     so it stays far darker than the water but keeps its shape; the inside
//     of the open hull gets less light.

// ---- tunables ---------------------------------------------------------------
const vec3  BOAT_POS        = vec3(0.0, 0.0, 13.0); // centre of the hull at the waterline (m)
const float BOAT_YAW        = 0.42;     // heading: 0 = broadside, > 0 = bow turned away (radians)
const float BOAT_LEN        = 3.8;      // length over all at the sheer (m)
const float BOAT_BEAM       = 1.3;      // greatest beam at the gunwale (m)
const float BOAT_FREEBOARD  = 0.31;     // gunwale height at its lowest point above the waterline (m)
const float BOAT_BOW_RISE   = 0.24;     // sheer rise toward the bow (m)
const float BOAT_STERN_RISE = 0.10;     // sheer rise toward the stern (m)
const float BOAT_BOW_RAKE   = 0.45;     // how far the stem leans forward from the waterline to the top (m)
const float BOAT_STERN_RAKE = 0.18;     // transom lean (m)
const float BOAT_TRANSOM    = 0.58;     // transom width relative to the beam
const float BOAT_WALL       = 0.025;    // planking thickness (m)
const float BOAT_RAIL       = 0.022;    // rub rail: how far it stands proud ...
const float BOAT_RAIL_H     = 0.04;     // ... and its height under the gunwale (m)
const float BOAT_LOCK_X     = -0.12;    // rowlock position along the hull from the centre (m)
const float BOAT_LOCK_H     = 0.09;     // rowlock height above the gunwale (m)
const float BOAT_OAR_LEN    = 2.2;      // oar length (m) ...
const float BOAT_OAR_IN     = 0.62;     // ... of which inboard of the rowlock (m)
const vec2  BOAT_OAR_SWEEP  = vec2(-0.55, -1.25); // near, far oar: angle aft from square to the hull (radians, < 0 = forward)
const float BOAT_OAR_FEATHER = 0.6;     // blade tilt from flat on the water (radians)
const float BOAT_OAR_DIP    = 0.12;     // how far the blade tip sinks below the waterline (m)
const vec2  BOAT_BLADE      = vec2(0.55, 0.19); // blade length and greatest width (m)
// Riding the swells.
const vec3  BOAT_RIDE       = vec3(1.0, 0.85, 0.8); // heave, pitch, roll response (1 = follows the surface)
const vec2  BOAT_PROBE      = vec2(1.45, 0.55);     // swell probes along and across the hull (m)
// Lighting (linear radiance of the surroundings).
const vec3  BOAT_ALBEDO     = vec3(0.062, 0.057, 0.052);   // dark, weathered paint (overall brightness)
const vec3  BOAT_SKY        = vec3(0.004, 0.075, 0.13); // sky overhead
const vec3  BOAT_GLOW       = vec3(0.06, 0.24, 0.30);   // horizon haze and aurora beyond the boat
const vec3  BOAT_SEA        = vec3(0.002, 0.10, 0.16);  // the sea, lighting the hull from below
const float BOAT_INSIDE_AO  = 0.35;     // light left deep inside the open hull
const float BOAT_REFL_BLUR  = 0.02;     // extra edge blur of the reflection (m)
const vec2  BOAT_SEA_REACH  = vec2(3.0, 5.0); // true swell height used up to this distance from the hull centre, fading out by the second (m)
const int   BOAT_STEPS      = 64;       // sphere-tracing steps inside the bounding box

// Sheer height at x (bow at +x), stem and transom positions at height y.
float boatSheer(float x) {
    float xn = clamp(x / (0.5 * BOAT_LEN) + 0.1, -1.0, 1.0); // lowest point a little aft
    return BOAT_FREEBOARD + xn * xn * (xn > 0.0 ? BOAT_BOW_RISE * (0.7 + 0.3 * xn) : BOAT_STERN_RISE);
}
float boatStem(float y) {
    float s = clamp(y / (BOAT_FREEBOARD + BOAT_BOW_RISE), 0.0, 1.0);
    return 0.5 * BOAT_LEN - BOAT_BOW_RAKE * (1.0 - s) * (1.0 - s) + 0.6 * min(y, 0.0); // curved forefoot
}
float boatTransom(float y) {
    return -0.5 * BOAT_LEN + BOAT_STERN_RAKE * (1.0 - clamp(y / (BOAT_FREEBOARD + BOAT_STERN_RISE), 0.0, 1.0));
}

// Half-beam of the hull at (x, y): planform from transom to stem, narrowing
// toward the keel (flared U sections).
float boatHalfBeam(float x, float y, float xs, float xt, float sheer) {
    float u = clamp((x - xt) / (xs - xt), 0.0, 1.0); // 0 at the transom, 1 at the stem
    float a = clamp((u - 0.42) / 0.58, 0.0, 1.0);
    float c = clamp((0.42 - u) / 0.42, 0.0, 1.0);
    float plan = (1.0 - a * a) * (1.0 - (1.0 - BOAT_TRANSOM) * c * c);
    float sect = pow(clamp((y + 0.3) / (sheer + 0.3), 0.0, 1.0), 0.35);
    return 0.5 * BOAT_BEAM * plan * sect;
}

// One oar, pointing out to +z, relative to its pivot in the rowlock: a
// round loom with a thinner handle inboard and a tapering blade outboard,
// dropped just enough for the blade tip to dip BOAT_OAR_DIP below the waterline.
float boatOar(vec3 q, float sweep) {
    float out_ = BOAT_OAR_LEN - BOAT_OAR_IN;
    float drop = asin((boatSheer(BOAT_LOCK_X) + 0.045 + BOAT_OAR_DIP) / out_);
    vec3 d = vec3(-sin(sweep) * cos(drop), -sin(drop), cos(sweep) * cos(drop));
    vec3 w = normalize(cross(vec3(0.0, 1.0, 0.0), d)); // flat blade: width axis level ...
    vec3 n = cross(d, w);
    float cf = cos(BOAT_OAR_FEATHER), sf = sin(BOAT_OAR_FEATHER); // ... then tilted about the loom
    vec3 wf = cf * w + sf * n, nf = cf * n - sf * w;
    float a = dot(q, d);
    float loom = length(q - clamp(a, -BOAT_OAR_IN, out_ - 0.5 * BOAT_BLADE.x) * d)
               - (a < -0.45 ? 0.016 : 0.021); // handle, then loom
    // Blade: a thin slab whose width grows toward the tip, rounded off there.
    float u = clamp((a - (out_ - BOAT_BLADE.x)) / BOAT_BLADE.x, 0.0, 1.0);
    float hw = BOAT_BLADE.y * (0.3 + 0.2 * sqrt(u));
    vec3 b = vec3(abs(a - (out_ - 0.5 * BOAT_BLADE.x)) - 0.5 * BOAT_BLADE.x,
                  abs(dot(q, wf)) - hw, abs(dot(q, nf)) - 0.012);
    float blade = length(max(b, 0.0)) + min(max(b.x, max(b.y, b.z)), 0.0);
    return min(loom, blade);
}

// Distance field in the boat frame (x forward, y up, z across).
float boatSdf(vec3 p) {
    float sheer = boatSheer(p.x);
    float xs = boatStem(p.y), xt = boatTransom(p.y);
    float hb = boatHalfBeam(p.x, p.y, xs, xt, sheer);
    float ends = max(p.x - xs, xt - p.x);
    float hull = max(max(abs(p.z) - hb, p.y - sheer), max(ends, -0.3 - p.y));
    float cavity = max(max(abs(p.z) - (hb - BOAT_WALL), -0.15 - p.y),
                       max(p.x - (xs - 3.0 * BOAT_WALL), (xt + BOAT_WALL) - p.x));
    hull = max(hull, -cavity);
    // Rub rail: a strip standing proud just under the gunwale.
    float rail = max(max(abs(abs(p.z) - hb + 0.5 * (BOAT_WALL - BOAT_RAIL)) - 0.5 * (BOAT_WALL + BOAT_RAIL),
                         abs(p.y - sheer + 0.5 * BOAT_RAIL_H) - 0.5 * BOAT_RAIL_H),
                     max(p.x - xs + 0.05, xt + 0.01 - p.x));
    hull = min(hull, rail);
    // Rowlocks: a socket block on each gunwale with two horns (a fork).
    float ls = boatSheer(BOAT_LOCK_X);
    float lz = boatHalfBeam(BOAT_LOCK_X, ls, boatStem(ls), boatTransom(ls), ls) - 0.5 * BOAT_WALL;
    vec3 l = vec3(p.x - BOAT_LOCK_X, p.y - ls, abs(p.z) - lz);
    vec3 b = abs(l - vec3(0.0, 0.015, 0.0)) - vec3(0.035, 0.015, 0.02);
    float lock = length(max(b, 0.0)) + min(max(b.x, max(b.y, b.z)), 0.0);
    vec2 horn = vec2(abs(l.x) - 0.028, l.z);
    lock = min(lock, max(length(horn) - 0.009, abs(l.y - 0.5 * BOAT_LOCK_H) - 0.5 * BOAT_LOCK_H));
    // Oars: +z is the far side (away from the camera), mirrored for the near one.
    vec3 pv = vec3(BOAT_LOCK_X, ls + 0.045, lz);
    float oar = min(boatOar(vec3(p.x, p.y, -p.z) - pv, BOAT_OAR_SWEEP.x),
                    boatOar(p - pv, BOAT_OAR_SWEEP.y));
    return min(min(hull, lock), oar);
}

// Normal over a pixel-sized neighbourhood (e ~ footprint), so thin strips
// (gunwale cap, rail) shade by how much of the pixel they fill instead of
// flickering.
vec3 boatNormal(vec3 p, float e0) {
    vec2 e = vec2(e0, -e0);
    return normalize(e.xyy * boatSdf(p + e.xyy) + e.yyx * boatSdf(p + e.yyx) +
                     e.yxy * boatSdf(p + e.yxy) + e.xxx * boatSdf(p + e.xxx));
}

// Shade a point of the boat (boat frame p, normal n): sky from above, glow
// from beyond the boat (glowDir), the sea from below, and less of everything
// deep inside the open hull.
vec3 boatShade(vec3 p, vec3 n, vec3 glowDir) {
#if VIEW == 6
    return vec3(1.0, 0.0, 0.0); // look-dev: boat (and its reflection) in flat red
#else
    vec3 e = BOAT_SKY * (0.5 + 0.5 * n.y)
           + BOAT_GLOW * 0.35 * max(dot(n, glowDir), 0.0)
           + BOAT_SEA * 0.6 * (0.5 - 0.5 * n.y);
    float sheer = boatSheer(p.x);
    float hb = boatHalfBeam(p.x, p.y, boatStem(p.y), boatTransom(p.y), sheer);
    float inside = step(abs(p.z), hb - 0.5 * BOAT_WALL) * smoothstep(0.0, 0.25, sheer - p.y);
    return BOAT_ALBEDO * e * mix(1.0, BOAT_INSIDE_AO, inside);
#endif
}

float boatSeaHeight(vec2 xz) {
    float r = length(xz - BOAT_POS.xz);
    if (r >= BOAT_SEA_REACH.y) return 0.0;
    return waterSwellHeight(xz) * (1.0 - smoothstep(BOAT_SEA_REACH.x, BOAT_SEA_REACH.y, r));
}

// Heave, pitch (bow up > 0) and roll (far side up > 0) from the swell under
// the hull.
vec3 boatRide(vec2 axis, vec2 nrm) {
    vec2 c = BOAT_POS.xz;
    float hBow   = waterSwellHeight(c + BOAT_PROBE.x * axis);
    float hStern = waterSwellHeight(c - BOAT_PROBE.x * axis);
    float hFar   = waterSwellHeight(c + BOAT_PROBE.y * nrm);
    float hNear  = waterSwellHeight(c - BOAT_PROBE.y * nrm);
    float hMid   = waterSwellHeight(c);
    float heave = (hBow + hStern + hFar + hNear + 2.0 * hMid) / 6.0;
    float pitch = atan(hBow - hStern, 2.0 * BOAT_PROBE.x);
    float roll  = atan(hFar - hNear, 2.0 * BOAT_PROBE.y);
    return BOAT_RIDE * vec3(heave, pitch, roll);
}

vec4 boat(vec3 ro, vec3 rd, float footprint, float soft, out float t) {
    t = 0.0;
    // World -> yawed boat frame.
    vec2 axis = vec2(cos(BOAT_YAW), sin(BOAT_YAW)); // bow direction in xz
    vec2 nrm = vec2(-axis.y, axis.x);                // far side in xz
    vec3 o = ro - BOAT_POS;
    o = vec3(dot(o.xz, axis), o.y, dot(o.xz, nrm));
    vec3 d = vec3(dot(rd.xz, axis), rd.y, dot(rd.xz, nrm));

    // Bounding box (with a margin for the antialiased edge). A coarse test
    // with room for the motion comes first, so the swell is only sampled for
    // rays near the boat.
    float zo = 0.5 * BOAT_BEAM + (BOAT_OAR_LEN - BOAT_OAR_IN) + 0.15; // oar tips
    vec3 bmin = vec3(-0.5 * BOAT_LEN - 0.08, -0.32, -zo);
    vec3 bmax = vec3( 0.5 * BOAT_LEN + 0.08, BOAT_FREEBOARD + BOAT_BOW_RISE + 0.12, zo);
    vec3 inv = 1.0 / d;
    vec3 ta = (bmin - 0.35 - o) * inv, tb = (bmax + 0.35 - o) * inv;
    vec3 tn = min(ta, tb), tf = max(ta, tb);
    if (max(max(max(tn.x, tn.y), tn.z), 0.0) >= min(min(tf.x, tf.y), tf.z)) return vec4(0.0);

    // Ride the swell: heave, pitch and roll.
    vec3 ride = boatRide(axis, nrm);
    o.y -= ride.x;
    o.xy = rot(-ride.y) * o.xy; d.xy = rot(-ride.y) * d.xy;
    o.zy = rot(-ride.z) * o.zy; d.zy = rot(-ride.z) * d.zy;

    inv = 1.0 / d;
    ta = (bmin - o) * inv; tb = (bmax - o) * inv;
    tn = min(ta, tb); tf = max(ta, tb);
    float t0 = max(max(max(tn.x, tn.y), tn.z), 0.0);
    float t1 = min(min(tf.x, tf.y), tf.z);
    if (t0 >= t1) return vec4(0.0);

    // Sphere trace, keeping the closest approach (relative to the pixel
    // footprint): a hit covers the pixel, a near miss fades out over one
    // footprint (the walls are too thin to measure how deep a ray goes in).
    float s = t0, best = 1e9, tBest = t0;
    for (int i = 0; i < BOAT_STEPS; i++) {
        float h = 0.7 * boatSdf(o + s * d); // the field is not exact: under-step
        float w = s * footprint + soft;
        if (h / w < best) { best = h / w; tBest = s; }
        if (h < 0.02 * w) { best = 0.0; break; }
        s += max(h, 0.25 * w);
        if (s > t1) break;
    }
    float cov = clamp(1.0 - best, 0.0, 1.0);
    if (cov <= 0.0) return vec4(0.0);
    t = tBest;

    // Cut off at the true swell height: the waterline follows the swells.
    // The edge reaches half a footprint into the water, so the hull and its
    // reflection overlap there instead of both fading to half coverage and
    // leaving a light seam that makes the boat look lifted.
    vec3 pw = ro + tBest * rd;
    float w = tBest * footprint + soft;
    cov *= clamp((pw.y - waterSwellHeight(pw.xz)) / w + 1.0, 0.0, 1.0);
    if (cov <= 0.0) return vec4(0.0);

    vec3 p = o + tBest * d;
    vec3 n = boatNormal(p, max(0.004, 0.5 * w));
    // Glow from beyond the boat (world +z, a little up), in the boat frame.
    vec3 g = normalize(vec3(0.0, 0.25, 1.0));
    g = vec3(dot(g.xz, axis), g.y, dot(g.xz, nrm));
    g.xy = rot(-ride.y) * g.xy; g.zy = rot(-ride.z) * g.zy;
    return vec4(boatShade(p, n, g), cov);
}
