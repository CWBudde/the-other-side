# The Other Side

A GLSL night-sea scene: a teal starry sky, two broad cyan-green aurora ribbons low
over the horizon, and a calm sea with long swells that reflects the sky. It recreates
the look of the "The Other Side" visualizer (without its boat).

The scene is written in Shadertoy form (`mainImage`) and split into include files.
A small Go runner (go-gl 4.1 core + GLFW 3.3) renders it in a window with hot reload,
renders deterministic screenshots and comparison montages, benchmarks it, and bundles
everything into a single file that you can paste into Shadertoy.

## Layout

| Path                                                  | Content                                                               |
| ----------------------------------------------------- | --------------------------------------------------------------------- |
| `shaders/main.glsl`                                   | camera, layer composition (`skyFull`, `skyRefl`), post process        |
| `shaders/common.glsl`                                 | framing constants, step counts, prototypes, hashes, noise             |
| `shaders/sky.glsl`                                    | `skyBase`: gradient, horizon haze, twinkling star field               |
| `shaders/aurora.glsl`                                 | `aurora`: nimitz's volumetric aurora with an arc band mask and motion |
| `shaders/meteors.glsl`                                | `meteors`: occasional shooting stars, right to left                   |
| `shaders/water.glsl`                                  | `water`: analytic sea plane, filtered swells and ripples              |
| `main.go`, `render.go`, `preprocess.go`, `compare.go` | the runner                                                            |
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
| `-bundle OUT.glsl`    | write one self-contained Shadertoy file (includes inlined, defines applied)           |

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

With `VIEW=2`, `-D AUR_DEBUG=1` shows the arc masks (red = main arc, green = second
arc) and `-D AUR_DEBUG_ALPHA=1` shows the aurora coverage. Other overridable defines:
`EXPOSURE`, `AURORA_STEPS` (direct view, default 40) and `AURORA_STEPS_REFL` (water
reflections, default 12). `-D METEOR_FORCE=1` puts a meteor in every 4 s slot, with
its head mid-frame at t = 4k + 0.7, which helps when taking screenshots.

Sky brightness: `SKY_DIM` / `SKY_DIM_TL` (`sky.glsl`, overall / top left corner; the
water reflections are not dimmed). The main dials for the animation: `STAR_TWINKLE`
(`sky.glsl`), `AUR_MOTION` (`aurora.glsl`, 0 = nearly static) and
`METEOR_SLOT`/`METEOR_PROB` (`meteors.glsl`, rate).

### justfile recipes

| Recipe                                                 | Does                                                                      |
| ------------------------------------------------------ | ------------------------------------------------------------------------- |
| `just run [args]`                                      | window mode with hot reload (also the default recipe)                     |
| `just shot [times] [args]`                             | offscreen shots into `out/`                                               |
| `just clip [start] [dur] [fps] [args]`                 | frame sequence into `out/clip/`, encoded as `out/clip.mp4` (needs ffmpeg) |
| `just sheet [dir] [every] [grid] [crop] [width] [out]` | contact sheet of every n-th frame, for judging motion                     |
| `just compare REF [times] [args]`                      | shots plus `_cmp` montages against `REF` (e.g. an earlier render)         |
| `just bench [dur] [args]`                              | benchmark at 1280x720 and 1920x1080                                       |
| `just bundle [args]`                                   | write `out/shadertoy.glsl` and render it back as a check                  |
| `just setup-deps`                                      | install treefmt, prettier, gofumpt, gci, shfmt, golangci-lint             |
| `just fmt`                                             | format with treefmt (`treefmt.toml`; GLSL is not formatted)               |
| `just lint` / `just lint-fix`                          | golangci-lint with `.golangci.toml`                                       |
| `just fix`                                             | `lint-fix`, then `fmt`                                                    |
| `just check`                                           | formatted, lint, `go mod tidy -diff`, build and vet                       |

Extra runner flags can be appended, for example `just shot 0,10 -D VIEW=3`.

## Performance

On Mesa Iris Xe (ADL GT2), the full scene takes about 10 ms/frame at 1280x720 and
about 22.5 ms/frame at 1920x1080.

## Credits and licence

The aurora in `shaders/aurora.glsl` is derived from **"Auroras" by nimitz**
(<https://www.shadertoy.com/view/XtGGRt>, twitter @stormoid), licensed under
[Creative Commons Attribution-NonCommercial-ShareAlike 3.0 Unported](https://creativecommons.org/licenses/by-nc-sa/3.0/).
The derived aurora shader inherits that licence (non-commercial, share alike), and so
do the bundled `out/shadertoy.glsl` and any other build that contains it. nimitz's
original header and notes are kept in the file.

The hash functions in `common.glsl` follow Dave Hoskins' "Hash without Sine" (MIT).
The gradient noise with analytic derivatives in `water.glsl` follows Inigo Quilez (MIT).
