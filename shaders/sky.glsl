// sky.glsl - night sky without the aurora.
//
// Contract: vec3 skyBase(vec3 rd)  -> linear RGB for view direction rd.
//           vec3 skyBase(vec3 rd, float starGain)  same with scaled stars.
//
// The gradient is calibrated against reference/reference.png: a saturated
// deep blue-teal zenith, a teal mid sky and a greyer cyan haze near the
// horizon with a faint brighter band just above it. Stars are a few layers of
// cell-hashed points on (azimuth, elevation), drawn as flux-preserving
// Gaussians whose width never drops below a pixel footprint, so they stay
// stable under the slow camera yaw at any resolution.

// ---- gradient tunables (colours are sRGB hex, converted to linear) ----------
const int   SKY_TOP        = 0x003f5b; // zenith colour (frame top is ~23 deg up)
const int   SKY_LIFT       = 0x007280; // added toward the horizon (falloff SKY_LIFT_H)
const float SKY_LIFT_H     = 0.17;     // Gaussian width of the lift in rd.y
const int   SKY_HAZE       = 0x8ea5a0; // greyish cyan haze the horizon blends into
const int   SKY_BAND       = 0x262c2c; // extra glow of the thin band just above the horizon
const float SKY_BAND_Y     = 0.016;    // band centre in rd.y
const float SKY_BAND_W     = 0.014;    // band half-width in rd.y
// The reference sky is not symmetric: it is brightest a little right of centre
// (under the aurora's right half), darkest at the left edge, and its horizon
// haze is grey on the right but blue-teal on the left. A skewed Gaussian in
// azimuth ("side") drives both. LO == HI disables either effect.
const float SKY_SIDE_AZ    = 0.38;     // azimuth of the brightest part (radians, +x = right)
const float SKY_SIDE_WL    = 0.65;     // Gaussian width toward the left (radians)
const float SKY_HAZE_WL    = 0.42;     // same for the horizon haze (darker gap under the aurora's left arm)
const float SKY_SIDE_WR    = 0.30;     // Gaussian width toward the right (radians)
const float SKY_GAIN_LO    = 0.70;     // gradient gain far from SKY_SIDE_AZ
const float SKY_GAIN_HI    = 1.58;     // gradient gain at SKY_SIDE_AZ
const float SKY_HAZE_LO    = 0.08;     // haze blend weight at the horizon, far side
const float SKY_HAZE_HI    = 0.85;     // haze blend weight at the horizon, bright side
const float SKY_HAZE_HLO   = 0.065;    // Gaussian width of the haze in rd.y, far side
const float SKY_HAZE_HHI   = 0.095;    // Gaussian width of the haze in rd.y, bright side

// ---- star tunables ----------------------------------------------------------
// Per layer: cell size (radians), probability of a star per cell and the peak
// linear brightness of the brightest star at 1080p. Brightness inside a layer
// is skewed toward faint stars by STAR_SKEW.
const float STAR_CELL[3]   = float[](0.0105, 0.020, 0.050);
const float STAR_PROB[3]   = float[](0.75, 0.6, 0.5);
const float STAR_PEAK[3]   = float[](0.16, 0.42, 1.1);
const float STAR_SKEW      = 2.6;      // brightness = peak * h^SKEW
const float STAR_SIZE      = 2.2e-4;   // intrinsic angular sigma (radians), ~0.35 px at 1080p
const float STAR_AA        = 0.42;     // minimum sigma in pixels (antialiasing footprint)
const float STAR_EXT       = 0.055;    // haze extinction per airmass; stars fade toward the horizon
const float STAR_TWINKLE   = 0.25;     // twinkle depth high up; grows with airmass

// Gaussian star field on (azimuth, elevation) cells. rd must be normalized,
// az = atan(rd.x, rd.z). The azimuth seam is behind the camera.
vec3 skyStars(vec3 rd, float az) {
    float el = asin(clamp(rd.y, -1.0, 1.0));
    vec2 sp = vec2(az, el);
    float cosEl = cos(el);

    // Angular size of a pixel (lens centre); the footprint widens tiny stars so
    // a star never collapses below a pixel, and the flux is kept constant.
    float pa = 1.0 / (iResolution.y * FOCAL);
    float s2 = STAR_SIZE * STAR_SIZE;
    float sigma2 = s2 + (STAR_AA * pa) * (STAR_AA * pa);
    float ref = STAR_AA / (1080.0 * FOCAL);
    float norm = (s2 + ref * ref) / sigma2; // peak scale relative to 1080p

    float airmass = 1.0 / (max(rd.y, 0.0) + 0.012);
    float ext = exp(-STAR_EXT * airmass) * smoothstep(-0.005, 0.01, rd.y);
    float twAmt = STAR_TWINKLE * clamp(airmass * 0.08, 1.0, 3.0);

    vec3 col = vec3(0.0);
    for (int i = 0; i < 3; i++) {
        float cell = STAR_CELL[i];
        vec2 g = sp / cell;
        vec2 id = floor(g);
        vec3 h = hash33i(ivec3(id, 7919 * i + 17));
        if (h.z > STAR_PROB[i]) continue;
        vec3 k = hash33i(ivec3(id, 7919 * i + 18));

        // Jitter is kept off the cell border so the 3-sigma disc is never cut.
        vec2 d = (fract(g) - (0.2 + 0.6 * h.xy)) * cell;
        d.x *= cosEl;
        float shape = exp(-dot(d, d) / (2.0 * sigma2));

        float u = h.z / STAR_PROB[i]; // uniform in [0, 1) for the stars that exist
        float b = STAR_PEAK[i] * pow(k.x, STAR_SKEW);
        float t = iTime * (1.5 + 3.0 * k.y) + TAU * k.z;
        b *= 1.0 + twAmt * 0.5 * (sin(t) + sin(1.73 * t + 2.0));

        // Mostly white to faintly blue, a rare warm one.
        vec3 tint = mix(vec3(0.78, 0.9, 1.0), vec3(1.0), fract(u * 7.0));
        tint = u > 0.95 ? vec3(1.0, 0.9, 0.78) : tint;

        // Layers whose cells shrink to a few pixels fade out instead of aliasing.
        float lod = smoothstep(3.0, 6.0, cell / pa);
        col += tint * (b * shape * lod);
    }
    return col * norm * ext;
}

// starGain scales the star field: the water reflections pass 0, since moving
// sub-pixel star glints on the waves only sparkle and flicker.
vec3 skyBase(vec3 rd, float starGain) {
    float y = max(rd.y, 0.0);
    float az = atan(rd.x, rd.z);
    float s = az - SKY_SIDE_AZ;
    float sh = s / (s < 0.0 ? SKY_HAZE_WL : SKY_SIDE_WR);
    s /= s < 0.0 ? SKY_SIDE_WL : SKY_SIDE_WR;
    float side = exp(-s * s);
    float sideHaze = exp(-sh * sh);

    vec3 col = hexColor(SKY_TOP) + hexColor(SKY_LIFT) * exp(-(y * y) / (SKY_LIFT_H * SKY_LIFT_H));
    col *= mix(SKY_GAIN_LO, SKY_GAIN_HI, side);
    float hh = y / mix(SKY_HAZE_HLO, SKY_HAZE_HHI, sideHaze);
    float haze = mix(SKY_HAZE_LO, SKY_HAZE_HI, sideHaze) * exp(-hh * hh);
    col = mix(col, hexColor(SKY_HAZE), haze);
    float band = (y - SKY_BAND_Y) / SKY_BAND_W;
    col += hexColor(SKY_BAND) * max(1.0 - band * band, 0.0);
    if (starGain > 0.0) col += skyStars(rd, az) * starGain;
    return col;
}

vec3 skyBase(vec3 rd) { return skyBase(rd, 1.0); }
