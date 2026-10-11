# The Other Side

A GLSL night-sea scene: a teal starry sky, two broad cyan-green aurora ribbons low
over the horizon, and a calm sea with long swells that reflects the sky, with an empty
rowing boat with its resting oars, dark against the light, riding the swells. It recreates the look of the "The Other Side"
visualizer.

The scene is written in Shadertoy form (`mainImage`) and split into include files.
A small Go runner (go-gl 4.1 core + GLFW 3.3) renders it in a window with hot reload,
renders deterministic screenshots and comparison montages, benchmarks it, and bundles
it into self-contained files that you can paste into Shadertoy.

It runs as two passes, like a Shadertoy with a buffer: Buffer A (`buffer_a.glsl`)
renders the scene in linear RGB, and the Image pass (`main.glsl`) blends in a soft glow
built from Buffer A's mip chain, then tonemaps.

## Layout

| Path                                                  | Content                                                               |
| ----------------------------------------------------- | --------------------------------------------------------------------- |
| `shaders/buffer_a.glsl`                               | Buffer A: camera, layer composition (`skyFull`, `skyRefl`), linear    |
| `shaders/main.glsl`                                   | Image pass: glow from Buffer A's mip chain, tonemap, vignette, grain  |
| `shaders/common.glsl`                                 | framing constants, step counts, prototypes, hashes, noise             |
| `shaders/sky.glsl`                                    | `skyBase`: gradient, horizon haze, twinkling star field               |
| `shaders/aurora.glsl`                                 | `aurora`: nimitz's volumetric aurora with an arc band mask and motion |
| `shaders/meteors.glsl`                                | `meteors`: occasional shooting stars, right to left                   |
| `shaders/water.glsl`                                  | `water`: analytic sea plane, filtered swells and ripples              |
| `shaders/boat.glsl`                                   | `boat`: rowing boat (sphere-traced 3D hull) riding the swells         |
| `main.go`, `render.go`, `preprocess.go`, `compare.go` | the runner                                                            |
| `web/`                                                | WebGL2 player for the bundled passes (GitHub Pages)                   |
| `.github/workflows/pages.yml`                         | bundles the shaders and publishes `web/` to GitHub Pages              |
| `out/`                                                | render output (git-ignored)                                           |

Every shader file lists its tunables as constants at the top.

## Build note: `-buildvcs=false`

There is a stray, empty `/mnt/projekte/Code/.git` above this project. Go detects it
as a repository, fails to stamp VCS information, and aborts the build. Pass
`-buildvcs=false` (or set `GOFLAGS=-buildvcs=false`; the justfile does this). Leave
that directory alone. It is not part of this project.

## Usage

```sh
go run -buildvcs=false . [flags]
```

| Flag                  | Meaning                                                                               |
| --------------------- | ------------------------------------------------------------------------------------- |
| `-shader FILE`        | main shader (default `shaders/main.glsl`)                                             |
| `-size WxH`           | window/render size (default `1280x720`)                                               |
| `-D NAME=VALUE`       | inject a `#define` (repeatable)                                                       |
| `-shot OUT.png`       | render offscreen and exit                                                             |
| `-time T`             | `iTime` for `-shot`                                                                   |
| `-times a,b,c`        | several shots; files are named `OUT_tNN.N.png`                                        |
| `-frames N`, `-fps F` | with `-shot`: N frames from `-time` at F fps (default 30), named `OUT_00000.png`, ... |
| `-compare REF.png`    | with `-shot`: also write `OUT_cmp.png` (render left, `REF.png` right)                 |
| `-bench 3s`           | render offscreen for this long and print ms/frame                                     |
| `-bundle OUT.glsl`    | write the Image pass to OUT.glsl and Buffer A to `buffer_a.glsl` beside it            |
| `-bufa FILE`          | Buffer A shader for iChannel0 (default `auto`: `buffer_a.glsl` beside `-shader`)      |

Buffer A renders into a half-float texture with mipmaps, bound to iChannel0 of the
Image pass (`-bufa none` runs the Image pass alone). To use the bundle on Shadertoy,
paste `out/buffer_a.glsl` into a new Buffer A tab and `out/shadertoy.glsl` into the
Image tab, then set the Image tab's iChannel0 to Buffer A with filter `mipmap` and wrap
`clamp`.

Window mode (no `-shot`/`-bench`/`-bundle`) reloads the shader when any included file
changes. If the new version fails to compile, the error log is printed with `file:line`
and the old image keeps rendering. Keys: `Space` pauses, `P` saves a PNG, `Esc` quits.
`iMouse` follows Shadertoy conventions.

`#include "file"` paths are relative to the including file and must stay inside the
directory of the main shader (they are read through an `os.Root`).

Examples:

```sh
go run -buildvcs=false .                                          # window
go run -buildvcs=false . -shot out/x.png -times 0,20,45 -compare out/before.png
go run -buildvcs=false . -D VIEW=2 -D AUR_DEBUG=1 -shot out/masks.png
go run -buildvcs=false . -bench 3s -size 1920x1080
go run -buildvcs=false . -shot out/seq/f.png -time 10 -frames 90 -fps 30
go run -buildvcs=false . -bundle out/shadertoy.glsl
```

### Layer views (`-D VIEW=n`)

| VIEW | Shows                                          |
| ---- | ---------------------------------------------- |
| 0    | full composite (default)                       |
| 1    | sky only (`skyBase`, no aurora)                |
| 2    | aurora only                                    |
| 3    | water only                                     |
| 4    | water normals (red = x slope, green = z slope) |
| 5    | meteors only                                   |
| 6    | full composite with the boat in red            |

With `VIEW=2`, `-D AUR_DEBUG=1` shows the arc masks (red = main arc, green = second
arc) and `-D AUR_DEBUG_ALPHA=1` shows the aurora coverage. Other overridable defines:
`EXPOSURE`, `GLOW_MIX` (softening glow, 0 = off), `AURORA_STEPS` (direct view, default 40) and `AURORA_STEPS_REFL` (water
reflections, default 12). `-D METEOR_FORCE=1` puts a meteor in every 4 s slot, with
its head mid-frame at t = 4k + 0.7, which helps when taking screenshots.

Sky brightness: `SKY_DIM` / `SKY_DIM_TL` (`sky.glsl`, overall / top left corner; the
water reflections are not dimmed). The main dials for the animation: `STAR_TWINKLE`
(`sky.glsl`), `AUR_MOTION` (`aurora.glsl`, 0 = nearly static) and
`METEOR_SLOT`/`METEOR_PROB` (`meteors.glsl`, rate). The boat (`boat.glsl`): `BOAT_POS`, `BOAT_YAW`,
`BOAT_LEN`/`BOAT_BEAM`/`BOAT_FREEBOARD`, the rowlocks `BOAT_LOCK_X`/`BOAT_LOCK_H`, the oars
`BOAT_OAR_LEN`/`BOAT_OAR_SWEEP`/`BOAT_OAR_FEATHER`, how closely it follows the swells
`BOAT_RIDE` (heave, pitch, roll) and its brightness `BOAT_ALBEDO`.

### justfile recipes

| Recipe                                                 | Does                                                                      |
| ------------------------------------------------------ | ------------------------------------------------------------------------- |
| `just run [args]`                                      | window mode with hot reload (also the default recipe)                     |
| `just shot [times] [args]`                             | offscreen shots into `out/`                                               |
| `just clip [start] [dur] [fps] [args]`                 | frame sequence into `out/clip/`, encoded as `out/clip.mp4` (needs ffmpeg) |
| `just sheet [dir] [every] [grid] [crop] [width] [out]` | contact sheet of every n-th frame, for judging motion                     |
| `just compare REF [times] [args]`                      | shots plus `_cmp` montages against `REF` (e.g. an earlier render)         |
| `just bench [dur] [args]`                              | benchmark at 1280x720 and 1920x1080                                       |
| `just bundle [args]`                                   | write `out/shadertoy.glsl` + `out/buffer_a.glsl`, render them as a check  |
| `just web [port] [args]`                               | bundle into `out/web` with the WebGL2 player and serve it on `:8000`      |
| `just setup-deps`                                      | install treefmt, prettier, gofumpt, gci, shfmt, golangci-lint             |
| `just fmt`                                             | format with treefmt (`treefmt.toml`; GLSL is not formatted)               |
| `just lint` / `just lint-fix`                          | golangci-lint with `.golangci.toml`                                       |
| `just fix`                                             | `lint-fix`, then `fmt`                                                    |
| `just check`                                           | formatted, lint, `go mod tidy -diff`, build and vet                       |

Extra runner flags can be appended, for example `just shot 0,10 -D VIEW=3`.

## Web version

Live at <https://meko-christian.github.io/the-other-side/>. On every push to `main`,
the Pages workflow bundles the shaders and publishes them with the small WebGL2 player
in `web/`, which runs the same two passes as the Go runner (Buffer A in a half-float
texture with mipmaps, then the Image pass). It renders at most 1080 lines and lowers
the resolution further when frames take longer than about 34 ms. `?scale=0.5` fixes
the render scale, `?t=20` sets the start time. Keys: `Space` pauses, `F` or a double
click toggles fullscreen. `just web` builds and serves the same site locally.

## Performance

On Mesa Iris Xe (ADL GT2), the full scene takes about 10 ms/frame at 1280x720 and
about 22.5 ms/frame at 1920x1080.

## Credits and licence

The aurora in `shaders/aurora.glsl` is derived from **"Auroras" by nimitz**
(<https://www.shadertoy.com/view/XtGGRt>, twitter @stormoid), licensed under
[Creative Commons Attribution-NonCommercial-ShareAlike 3.0 Unported](https://creativecommons.org/licenses/by-nc-sa/3.0/).
The derived aurora shader inherits that licence (non-commercial, share alike), and so
do the bundled `out/buffer_a.glsl` and any other build that contains it. nimitz's
original header and notes are kept in the file.

The hash functions in `common.glsl` follow Dave Hoskins' "Hash without Sine" (MIT).
The gradient noise with analytic derivatives in `water.glsl` follows Inigo Quilez (MIT).
