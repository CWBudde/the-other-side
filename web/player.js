// The Other Side - WebGL2 player for the bundled Shadertoy passes.
//
// Mirrors the Go runner: buffer_a.glsl renders the scene in linear RGB into a
// half-float texture with mipmaps (filter mipmap, wrap clamp), shadertoy.glsl
// reads it on iChannel0 and writes the final frame. Both files come from
// `go run . -bundle`.
//
// URL parameters: ?scale=0.75 fixes the render scale (default: adaptive, at
// most 1080 lines), ?t=20 starts at iTime 20.

const MAX_LINES = 1080; // render height cap at scale 1
const MIN_SCALE = 0.35; // adaptive scaling never goes below this
const SLOW_MS = 34; // average frame time that triggers a downscale

const canvas = document.getElementById("view");
const params = new URLSearchParams(location.search);

function fail(msg) {
  const el = document.getElementById("error");
  el.textContent = msg;
  el.hidden = false;
  throw new Error(msg);
}

const gl = canvas.getContext("webgl2", {
  antialias: false,
  alpha: false,
  depth: false,
});
if (!gl) fail("WebGL2 is not available in this browser.");

// Half-float rendering needs EXT_color_buffer_float. Without it the scene is
// stored in RGBA8: the glow still works, but highlights above 1 are clipped.
const floatTarget = gl.getExtension("EXT_color_buffer_float") !== null;

const vertexSource = `#version 300 es
void main() {
    vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
`;

// Same uniform set as the Go runner's fragmentPrefix.
const fragmentPrefix = `#version 300 es
precision highp float;
precision highp int;
precision highp sampler2D;
uniform vec3  iResolution;
uniform float iTime;
uniform float iTimeDelta;
uniform float iFrameRate;
uniform int   iFrame;
uniform vec4  iMouse;
uniform vec4  iDate;
uniform float iSampleRate;
uniform float iChannelTime[4];
uniform vec3  iChannelResolution[4];
uniform sampler2D iChannel0;
uniform sampler2D iChannel1;
uniform sampler2D iChannel2;
uniform sampler2D iChannel3;
out vec4 shadertoyFragColor;
`;

const fragmentPostfix = `
void main() {
    shadertoyFragColor = vec4(0.0, 0.0, 0.0, 1.0);
    mainImage(shadertoyFragColor, gl_FragCoord.xy);
    shadertoyFragColor.a = 1.0;
}
`;

function compile(type, source, name) {
  const sh = gl.createShader(type);
  gl.shaderSource(sh, source);
  gl.compileShader(sh);
  if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) {
    fail(`${name}: compile failed\n\n${gl.getShaderInfoLog(sh)}`);
  }
  return sh;
}

function buildPass(body, name) {
  const prog = gl.createProgram();
  gl.attachShader(prog, compile(gl.VERTEX_SHADER, vertexSource, "vertex"));
  gl.attachShader(
    prog,
    compile(gl.FRAGMENT_SHADER, fragmentPrefix + body + fragmentPostfix, name),
  );
  gl.linkProgram(prog);
  if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) {
    fail(`${name}: link failed\n\n${gl.getProgramInfoLog(prog)}`);
  }
  const loc = {};
  for (const n of [
    "iResolution",
    "iTime",
    "iTimeDelta",
    "iFrameRate",
    "iFrame",
    "iMouse",
    "iDate",
    "iChannel0",
    "iChannelResolution",
  ]) {
    loc[n] = gl.getUniformLocation(prog, n);
  }
  return { prog, loc };
}

async function fetchText(url) {
  const res = await fetch(url);
  if (!res.ok) fail(`${url}: ${res.status} ${res.statusText}`);
  return res.text();
}

const [imageSrc, bufferSrc] = await Promise.all([
  fetchText("shadertoy.glsl"),
  fetchText("buffer_a.glsl"),
]);
const bufA = buildPass(bufferSrc, "buffer_a.glsl");
const image = buildPass(imageSrc, "shadertoy.glsl");

gl.bindVertexArray(gl.createVertexArray());

// ---- Buffer A target ---------------------------------------------------------
let target = null; // { tex, fbo, w, h }

function makeTarget(w, h) {
  if (target) {
    gl.deleteFramebuffer(target.fbo);
    gl.deleteTexture(target.tex);
  }
  const levels = Math.floor(Math.log2(Math.max(w, h))) + 1;
  const tex = gl.createTexture();
  gl.bindTexture(gl.TEXTURE_2D, tex);
  gl.texStorage2D(
    gl.TEXTURE_2D,
    levels,
    floatTarget ? gl.RGBA16F : gl.RGBA8,
    w,
    h,
  );
  gl.texParameteri(
    gl.TEXTURE_2D,
    gl.TEXTURE_MIN_FILTER,
    gl.LINEAR_MIPMAP_LINEAR,
  );
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);

  const fbo = gl.createFramebuffer();
  gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
  gl.framebufferTexture2D(
    gl.FRAMEBUFFER,
    gl.COLOR_ATTACHMENT0,
    gl.TEXTURE_2D,
    tex,
    0,
  );
  if (gl.checkFramebufferStatus(gl.FRAMEBUFFER) !== gl.FRAMEBUFFER_COMPLETE) {
    fail("Buffer A framebuffer is incomplete.");
  }
  gl.bindFramebuffer(gl.FRAMEBUFFER, null);
  target = { tex, fbo, w, h };
}

// ---- sizing ------------------------------------------------------------------
const fixedScale = params.has("scale")
  ? Math.min(Math.max(parseFloat(params.get("scale")) || 1, 0.1), 2)
  : null;
let scale = fixedScale ?? 1;

function resize() {
  const dpr = window.devicePixelRatio || 1;
  let w = canvas.clientWidth * dpr;
  let h = canvas.clientHeight * dpr;
  const cap = Math.min(1, MAX_LINES / h);
  w = Math.max(1, Math.round(w * cap * scale));
  h = Math.max(1, Math.round(h * cap * scale));
  if (canvas.width !== w || canvas.height !== h) {
    canvas.width = w;
    canvas.height = h;
  }
  if (!target || target.w !== w || target.h !== h) makeTarget(w, h);
}

// ---- input -------------------------------------------------------------------
let paused = false;
window.addEventListener("keydown", (e) => {
  if (e.code === "Space") {
    paused = !paused;
    e.preventDefault();
  } else if (e.code === "KeyF") {
    if (document.fullscreenElement) document.exitFullscreen();
    else document.documentElement.requestFullscreen();
  }
});
canvas.addEventListener("dblclick", () => {
  if (document.fullscreenElement) document.exitFullscreen();
  else document.documentElement.requestFullscreen();
});

// ---- frame loop --------------------------------------------------------------
let time = parseFloat(params.get("t")) || 0;
let frame = 0;
let last = null;
let slowAvg = 0; // smoothed frame time for adaptive scaling
let settle = 30; // frames to skip after start or a scale change

function setUniforms(p, w, h, dt) {
  const now = new Date();
  gl.uniform3f(p.loc.iResolution, w, h, 1);
  gl.uniform1f(p.loc.iTime, time);
  gl.uniform1f(p.loc.iTimeDelta, dt);
  gl.uniform1f(p.loc.iFrameRate, dt > 0 ? 1 / dt : 60);
  gl.uniform1i(p.loc.iFrame, frame);
  gl.uniform4f(p.loc.iMouse, 0, 0, 0, 0);
  gl.uniform4f(
    p.loc.iDate,
    now.getFullYear(),
    now.getMonth(),
    now.getDate(),
    now.getHours() * 3600 + now.getMinutes() * 60 + now.getSeconds(),
  );
}

function adapt(ms) {
  if (fixedScale !== null || scale <= MIN_SCALE) return;
  if (settle > 0) {
    settle--;
    slowAvg = ms;
    return;
  }
  slowAvg += (ms - slowAvg) * 0.05;
  if (slowAvg > SLOW_MS) {
    scale = Math.max(MIN_SCALE, scale * 0.8);
    settle = 30;
  }
}

function draw(nowMs) {
  const dt = last === null ? 0 : Math.min((nowMs - last) / 1000, 0.1);
  last = nowMs;
  if (!paused) {
    time += dt;
    adapt(dt * 1000);
  }
  resize();
  const { w, h } = target;
  gl.viewport(0, 0, w, h);

  // Buffer A: the scene, then its mip chain for the glow.
  gl.bindTexture(gl.TEXTURE_2D, null);
  gl.bindFramebuffer(gl.FRAMEBUFFER, target.fbo);
  gl.useProgram(bufA.prog);
  setUniforms(bufA, w, h, dt);
  gl.drawArrays(gl.TRIANGLES, 0, 3);
  gl.bindTexture(gl.TEXTURE_2D, target.tex);
  gl.generateMipmap(gl.TEXTURE_2D);

  // Image: glow, tonemap, grain.
  gl.bindFramebuffer(gl.FRAMEBUFFER, null);
  gl.useProgram(image.prog);
  setUniforms(image, w, h, dt);
  gl.uniform1i(image.loc.iChannel0, 0);
  gl.uniform3fv(image.loc.iChannelResolution, [
    w,
    h,
    1,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
  ]);
  gl.drawArrays(gl.TRIANGLES, 0, 3);

  if (!paused) frame++;
  requestAnimationFrame(draw);
}

requestAnimationFrame(draw);
