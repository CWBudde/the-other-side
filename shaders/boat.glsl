// boat.glsl - an empty rowing boat, seen against the light as a dark silhouette.
//
// Contract: float boatCover(vec3 ro, vec3 rd, float footprint, float soft, out float t)
//   -> antialiased coverage (0..1) of the boat along the ray, t = ray distance
//      to the boat (only meaningful when the coverage is > 0). The edge width
//      is t * footprint + soft (footprint = pixel angle, soft = extra blur in
//      metres, used by the water reflection).
//
// The camera looks at the boat almost side-on (eye 1.2 m above the water, the
// boat ~16 m away), so the inside, the thwarts and the beam never show. The
// hull is therefore a 2D side profile on a vertical card standing in the sea,
// turned by BOAT_YAW: u runs along the hull (bow at +u), v is the height above
// the waterline. The profile is a signed distance (outside > 0): flat sheer
// rising toward a raked, slightly curved stem and, less, toward a small
// transom. Below the waterline it is cut off by the water itself: camera rays
// reach the card underwater only after hitting the sea, and reflection rays
// start at the surface. The boat heaves and pitches gently with the swells.

// ---- tunables ---------------------------------------------------------------
const vec3  BOAT_POS        = vec3(2.6, 0.0, 16.0); // centre of the hull at the waterline (m)
const float BOAT_YAW        = 0.45;     // heading: 0 = broadside, > 0 = bow turned away (radians)
const float BOAT_LEN        = 3.4;      // length over all (m)
const float BOAT_FREEBOARD  = 0.42;     // gunwale height amidships above the waterline (m)
const float BOAT_BOW_RISE   = 0.20;     // sheer rise toward the bow (m)
const float BOAT_STERN_RISE = 0.10;     // sheer rise toward the stern (m)
const float BOAT_BOW_RAKE   = 0.42;     // how far the stem leans forward from the waterline to the top (m)
const float BOAT_STERN_RAKE = 0.12;     // transom lean (m)
const vec2  BOAT_HEAVE      = vec2(0.022, 0.010); // heave amplitudes (m) of the two components
const vec2  BOAT_PITCH      = vec2(0.020, 0.008); // pitch amplitudes (radians)
const vec4  BOAT_PERIODS    = vec4(5.7, 3.3, 6.4, 3.9); // heave 1, 2, pitch 1, 2 (seconds)
#if VIEW == 6
const vec3  BOAT_COL        = vec3(1.0, 0.0, 0.0);       // look-dev: boat (and its reflection) in red
#else
const vec3  BOAT_COL        = vec3(0.002, 0.003, 0.005); // linear, near black with a hint of the night blue
#endif
const float BOAT_REFL_BLUR  = 0.02;     // extra edge blur of the reflection (m)

// Signed distance of the side profile (u, v in metres, outside > 0). Only the
// sheer, stem and transom matter; the bottom lies well under the water.
float boatProfile(vec2 q) {
    float h = 0.5 * BOAT_LEN;
    float x = clamp(q.x / h, -1.0, 1.0);
    float sheer = BOAT_FREEBOARD + x * x * (x > 0.0 ? BOAT_BOW_RISE : BOAT_STERN_RISE);
    float s = clamp(q.y / (BOAT_FREEBOARD + BOAT_BOW_RISE), 0.0, 1.0); // 0 at the waterline, 1 at the stem head
    float stem = h - BOAT_BOW_RAKE * (1.0 - s) * (1.0 - s);            // curved, leaning forward
    float transom = -h + BOAT_STERN_RAKE * (1.0 - clamp(q.y / (BOAT_FREEBOARD + BOAT_STERN_RISE), 0.0, 1.0));
    float d = max(q.y - sheer, -0.5 - q.y);
    return max(d, max(q.x - stem, transom - q.x));
}

float boatCover(vec3 ro, vec3 rd, float footprint, float soft, out float t) {
    t = 0.0;
    vec2 axis = vec2(cos(BOAT_YAW), sin(BOAT_YAW)); // bow direction in xz
    vec2 nrm = vec2(-axis.y, axis.x);                // card normal in xz
    float den = dot(rd.xz, nrm);
    if (abs(den) < 1e-4) return 0.0;
    t = dot(BOAT_POS.xz - ro.xz, nrm) / den;
    if (t <= 0.0) return 0.0;
    vec3 p = ro + t * rd;
    vec2 q = vec2(dot(p.xz - BOAT_POS.xz, axis), p.y - BOAT_POS.y);
    if (abs(q.x) > 0.6 * BOAT_LEN || q.y > 1.0 || q.y < -0.6) return 0.0;

    // Heave and pitch (bow up for a positive angle) about the waterline centre.
    vec4 ph = mod(TAU * iTime / BOAT_PERIODS + vec4(0.0, 1.3, 0.7, 2.1), TAU);
    float heave = dot(BOAT_HEAVE, sin(ph.xy));
    float pitch = dot(BOAT_PITCH, sin(ph.zw));
    q.y -= heave;
    q = rot(-pitch) * q;

    float w = t * footprint + soft;
    return clamp(0.5 - boatProfile(q) / w, 0.0, 1.0);
}
