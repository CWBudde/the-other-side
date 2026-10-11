// The Other Side - night sea under an aurora.
//
// Layer isolation for look-dev (runner: -D VIEW=n):
//   0 full composite   1 sky only (skyBase)   2 aurora only
//   3 water only       4 water normals (red = x slope, green = z slope)
//   5 meteors only (shooting stars; -D METEOR_FORCE=1 puts one in every slot)
//   6 full composite with the boat in red (look-dev; its reflection shows dim red)
#ifndef VIEW
#define VIEW 0
#endif

#ifndef EXPOSURE
#define EXPOSURE 1.0
#endif

#include "common.glsl"
#include "sky.glsl"
#include "aurora.glsl"
#include "meteors.glsl"
#include "boat.glsl"

vec3 skyFull(vec3 rd, int steps) {
    vec4 a = aurora(gCamPos, rd, steps);
    return skyBase(rd) * (1.0 - a.a) + a.rgb + meteors(rd);
}

vec3 skyFull(vec3 rd) { return skyFull(rd, AURORA_STEPS); }

// Sky as seen in the water: the aurora is looked up along its own, smoother
// reflection direction rdAur and scaled by AURORA_REFL_GAIN, so it only shows
// as a faint diffuse lift instead of bright patches, while the haze keeps its
// full reflection (the bright horizon band and the long sheen streaks).
// Stars and meteors are left out: their glints on the moving waves only flicker.
vec3 skyRefl(vec3 rd, vec3 rdAur, int steps) {
    vec4 a = aurora(gCamPos, rdAur, steps) * AURORA_REFL_GAIN;
    return skyBase(rd, 0.0) * (1.0 - a.a) + a.rgb;
}

#include "water.glsl"

// Coverage of the boat for a camera ray. Below the horizon the card only
// counts in front of the sea hit, which cuts the hull off at the waterline.
float boatCam(vec3 ro, vec3 rd) {
    float t;
    float c = boatCover(ro, rd, 1.0 / (iResolution.y * FOCAL), 0.0, t);
    return (rd.y < 0.0 && t > -ro.y / rd.y) ? 0.0 : c;
}

// Level camera with a shifted lens: rd.y = 0 (the horizon) lands at HORIZON
// of the frame height without tilting the view.
void camera(vec2 fragCoord, out vec3 ro, out vec3 rd) {
    ro = vec3(0.0, CAM_HEIGHT + 0.02 * sin(iTime * 0.4), 0.0);
    vec2 uv = (fragCoord - vec2(0.5 * iResolution.x, HORIZON * iResolution.y)) / iResolution.y;
    rd = normalize(vec3(uv, FOCAL));
    rd.xz = rot(0.02 * sin(iTime * 0.05)) * rd.xz; // slow yaw drift keeps the horizon level
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
    vec3 ro, rd;
    camera(fragCoord, ro, rd);
    gCamPos = ro;
    bool isSky = rd.y > 0.0;
    vec3 col = vec3(0.0);

#if VIEW == 0 || VIEW == 6
    if (isSky) col = skyFull(rd);
    else       col = water(ro, rd);
    col = mix(col, BOAT_COL, boatCam(ro, rd));
#elif VIEW == 1
    if (isSky) col = skyBase(rd);
#elif VIEW == 2
    if (isSky) col = aurora(ro, rd, AURORA_STEPS).rgb;
#elif VIEW == 3
    if (!isSky) col = mix(water(ro, rd), BOAT_COL, boatCam(ro, rd));
#elif VIEW == 4
    if (!isSky) {
        float t = -ro.y / rd.y;
        vec3 n = waterNormal((ro + t * rd).xz, t);
        fragColor = vec4(0.5 + 5.0 * n.x, 0.5 + 5.0 * n.z, 0.5, 1.0);
    } else {
        fragColor = vec4(0.0, 0.0, 0.0, 1.0);
    }
    return;
#elif VIEW == 5
    if (isSky) col = meteors(rd);
#endif

    fragColor = vec4(post(col, fragCoord), 1.0);
}
