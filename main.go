// Command the-other-side is a small Shadertoy-compatible GLSL runner with
// #include support, hot reload, deterministic screenshots, reference
// comparison montages, benchmarking and Shadertoy bundling.
package main

import (
	"errors"
	"flag"
	"fmt"
	"image"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/go-gl/gl/v4.1-core/gl"
	"github.com/go-gl/glfw/v3.3/glfw"
)

func init() {
	// GLFW and the GL context must stay on the main thread.
	runtime.LockOSThread()
}

type options struct {
	shader        string
	width, height int
	defines       defineList
	shot          string
	times         []float64
	frames        int // > 0: numbered frame sequence instead of -times
	compare       string
	bench         time.Duration
	bundle        string
}

func main() {
	opt, err := parseFlags()
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(2)
	}

	err = run(opt)
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func parseFlags() (*options, error) {
	opt := &options{}
	size := flag.String("size", "1280x720", "render/window size WxH")
	t := flag.Float64("time", 0, "iTime for -shot")
	times := flag.String("times", "", "comma-separated iTime list for -shot, e.g. 0,10,30")
	fps := flag.Float64("fps", 30, "frame rate for -frames")

	flag.StringVar(&opt.shader, "shader", "shaders/main.glsl", "main shader file (Shadertoy mainImage)")
	flag.Var(&opt.defines, "D", "define NAME=VALUE (repeatable), injected as #define")
	flag.StringVar(&opt.shot, "shot", "", "render offscreen to this PNG and exit")
	flag.IntVar(&opt.frames, "frames", 0,
		"with -shot: render this many frames from -time at -fps into <shot>_00000.png, ...")
	flag.StringVar(&opt.compare, "compare", "",
		"with -shot: also write <shot>_cmp.png montage against this reference image")
	flag.DurationVar(&opt.bench, "bench", 0, "render offscreen for this long and report ms/frame, e.g. 3s")
	flag.StringVar(&opt.bundle, "bundle", "", "write a single self-contained Shadertoy-pasteable file")
	flag.Parse()

	_, err := fmt.Sscanf(strings.ToLower(*size), "%dx%d", &opt.width, &opt.height)
	if err != nil || opt.width <= 0 || opt.height <= 0 {
		return nil, fmt.Errorf("invalid -size %q, want WxH", *size)
	}

	opt.times, err = shotTimes(*t, *times, *fps, opt.frames)
	if err != nil {
		return nil, err
	}

	if opt.compare != "" && opt.shot == "" {
		return nil, errors.New("-compare requires -shot")
	}

	return opt, nil
}

// shotTimes returns the iTime values for shot mode: start alone, the -times
// list, or a sequence of that many frames at fps beginning at start.
func shotTimes(start float64, list string, fps float64, frames int) ([]float64, error) {
	if frames > 0 {
		if fps <= 0 || list != "" {
			return nil, errors.New("-frames needs -fps > 0 and excludes -times")
		}

		times := make([]float64, frames)
		for i := range times {
			times[i] = start + float64(i)/fps
		}

		return times, nil
	}

	if list == "" {
		return []float64{start}, nil
	}

	var times []float64

	for s := range strings.SplitSeq(list, ",") {
		v, err := strconv.ParseFloat(strings.TrimSpace(s), 64)
		if err != nil {
			return nil, fmt.Errorf("invalid -times entry %q", s)
		}

		times = append(times, v)
	}

	return times, nil
}

// shotPath names shot i at time t: numbered for -frames, time-stamped for
// several -times, the plain -shot path otherwise.
func shotPath(opt *options, i int, t float64) string {
	ext := filepath.Ext(opt.shot)
	base := strings.TrimSuffix(opt.shot, ext)

	switch {
	case opt.frames > 0:
		return fmt.Sprintf("%s_%05d%s", base, i, ext)
	case len(opt.times) > 1:
		return fmt.Sprintf("%s_t%04.1f%s", base, t, ext)
	default:
		return opt.shot
	}
}

func run(opt *options) error {
	if opt.bundle != "" {
		err := writeBundle(opt)
		if err != nil {
			return err
		}

		if opt.shot == "" && opt.bench == 0 {
			return nil
		}
	}

	offscreen := opt.shot != "" || opt.bench > 0

	window, err := initGL(opt, !offscreen)
	if err != nil {
		return err
	}

	defer glfw.Terminate()
	defer window.Destroy()

	screen := newQuad()
	defer screen.delete()

	switch {
	case opt.shot != "":
		return runShot(opt, screen)
	case opt.bench > 0:
		return runBench(opt, screen)
	default:
		runWindow(opt, window, screen)
		return nil
	}
}

// writeBundle writes the single-file Shadertoy export to opt.bundle.
func writeBundle(opt *options) error {
	body, err := loadShader(opt.shader)
	if err != nil {
		return err
	}

	err = writeOutput(opt.bundle, func(w io.Writer) error {
		_, err := io.WriteString(w, bundle(body, opt.defines, opt.shader))
		return err
	})
	if err != nil {
		return err
	}

	fmt.Println("wrote", opt.bundle)

	return nil
}

func initGL(opt *options, visible bool) (*glfw.Window, error) {
	err := glfw.Init()
	if err != nil {
		return nil, fmt.Errorf("glfw init: %w", err)
	}

	glfw.WindowHint(glfw.ContextVersionMajor, 4)
	glfw.WindowHint(glfw.ContextVersionMinor, 1)
	glfw.WindowHint(glfw.OpenGLProfile, glfw.OpenGLCoreProfile)
	glfw.WindowHint(glfw.OpenGLForwardCompatible, glfw.True)

	if !visible {
		glfw.WindowHint(glfw.Visible, glfw.False)
	}

	window, err := glfw.CreateWindow(opt.width, opt.height, "the-other-side", nil, nil)
	if err != nil {
		glfw.Terminate()
		return nil, fmt.Errorf("create window: %w", err)
	}

	window.MakeContextCurrent()

	err = gl.Init()
	if err != nil {
		glfw.Terminate()
		return nil, fmt.Errorf("gl init: %w", err)
	}

	fmt.Fprintf(os.Stderr, "GL %s on %s\n", gl.GoStr(gl.GetString(gl.VERSION)), gl.GoStr(gl.GetString(gl.RENDERER)))

	return window, nil
}

func loadProgram(opt *options) (*program, *source, error) {
	body, err := loadShader(opt.shader)
	if err != nil {
		return nil, body, err
	}

	prog, err := buildProgram(body, opt.defines)

	return prog, body, err
}

// fixedUniforms returns deterministic inputs for offscreen frames at time t.
func fixedUniforms(opt *options, t float64) frameUniforms {
	return frameUniforms{
		width: opt.width, height: opt.height,
		time: float32(t), timeDelta: 1.0 / 60, frameRate: 60,
		frame: int32(t * 60),
		date:  [4]float32{2026, 0, 1, float32(t)},
	}
}

func runShot(opt *options, screen *quad) error {
	prog, _, err := loadProgram(opt)
	if err != nil {
		return err
	}
	defer prog.delete()

	target, err := newFBO(opt.width, opt.height)
	if err != nil {
		return err
	}
	defer target.delete()

	var ref image.Image
	if opt.compare != "" {
		ref, err = loadImage(opt.compare)
		if err != nil {
			return err
		}
	}

	for i, t := range opt.times {
		path := shotPath(opt, i, t)

		screen.draw(prog, fixedUniforms(opt, t))
		gl.Finish()

		err := writeShot(path, readPixels(opt.width, opt.height), ref, opt.frames == 0)
		if err != nil {
			return err
		}
	}

	if opt.frames > 0 {
		fmt.Printf("wrote %d frames to %s\n", opt.frames, shotPath(opt, 0, 0))
	}

	return nil
}

// writeShot writes img to path and, with a reference, the comparison montage.
func writeShot(path string, img *image.RGBA, ref image.Image, verbose bool) error {
	err := writePNG(path, img)
	if err != nil {
		return err
	}

	if verbose {
		fmt.Println("wrote", path)
	}

	if ref == nil {
		return nil
	}

	cmp := compareName(path)

	err = writePNG(cmp, montage(img, ref))
	if err != nil {
		return err
	}

	fmt.Println("wrote", cmp)

	return nil
}

func runBench(opt *options, screen *quad) error {
	prog, _, err := loadProgram(opt)
	if err != nil {
		return err
	}
	defer prog.delete()

	target, err := newFBO(opt.width, opt.height)
	if err != nil {
		return err
	}
	defer target.delete()

	for i := range 10 { // warm-up: shader compilation is often lazy
		screen.draw(prog, fixedUniforms(opt, float64(i)/60))
	}

	gl.Finish()

	start := time.Now()
	frames := 0

	for time.Since(start) < opt.bench {
		screen.draw(prog, fixedUniforms(opt, time.Since(start).Seconds()))
		gl.Finish()

		frames++
	}

	el := time.Since(start)
	ms := el.Seconds() * 1000 / float64(frames)
	fmt.Printf("%dx%d: %d frames in %.2fs, %.2f ms/frame, %.1f fps\n",
		opt.width, opt.height, frames, el.Seconds(), ms, 1000/ms)

	return nil
}

// mouseState tracks Shadertoy iMouse semantics: xy is the position while the
// button is held, zw the click position; z is negative once released and w is
// positive only on the frame of the click.
type mouseState struct {
	pos, click [2]float32
	down       bool
	clicked    bool
}

func (m *mouseState) uniform() [4]float32 {
	res := [4]float32{m.pos[0], m.pos[1], m.click[0], -m.click[1]}
	if !m.down {
		res[2] = -m.click[0]
	}

	if m.clicked {
		res[3] = m.click[1]
	}

	return res
}

// windowInput is the interactive state driven by GLFW input callbacks.
type windowInput struct {
	mouse    mouseState
	paused   bool
	saveShot bool
}

// attach installs the GLFW mouse and keyboard callbacks that update in.
func (in *windowInput) attach(window *glfw.Window) {
	cursor := func() [2]float32 {
		x, y := window.GetCursorPos()
		ww, wh := window.GetSize()
		fw, fh := window.GetFramebufferSize()
		sx, sy := float64(fw)/float64(ww), float64(fh)/float64(wh)

		return [2]float32{float32(x * sx), float32(float64(fh) - y*sy)}
	}

	window.SetCursorPosCallback(func(_ *glfw.Window, _, _ float64) {
		if in.mouse.down {
			in.mouse.pos = cursor()
		}
	})
	window.SetMouseButtonCallback(func(_ *glfw.Window, b glfw.MouseButton, a glfw.Action, _ glfw.ModifierKey) {
		if b != glfw.MouseButton1 {
			return
		}

		switch a {
		case glfw.Press:
			in.mouse.down, in.mouse.clicked = true, true
			in.mouse.pos = cursor()
			in.mouse.click = in.mouse.pos
		case glfw.Release:
			in.mouse.down = false
		}
	})
	window.SetKeyCallback(func(w *glfw.Window, k glfw.Key, _ int, a glfw.Action, _ glfw.ModifierKey) {
		if a != glfw.Press {
			return
		}

		switch k {
		case glfw.KeySpace:
			in.paused = !in.paused
		case glfw.KeyP:
			in.saveShot = true
		case glfw.KeyEscape:
			w.SetShouldClose(true)
		}
	})
}

func runWindow(opt *options, window *glfw.Window, screen *quad) {
	glfw.SwapInterval(1)

	prog, body, err := loadProgram(opt)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
	}

	watch := newWatcher(body.files)

	var (
		input     windowInput
		simTime   float64
		frame     int32
		last      = glfw.GetTime()
		fpsTime   = last
		fpsFrames int
		lastPoll  = last
	)

	input.attach(window)

	for !window.ShouldClose() {
		now := glfw.GetTime()
		delta := now - last
		last = now

		if !input.paused {
			simTime += delta
		}

		if now-lastPoll >= 0.25 {
			lastPoll = now
			prog = reloadProgram(opt, watch, prog)
		}

		fbWidth, fbHeight := window.GetFramebufferSize()
		screen.draw(prog, liveUniforms(fbWidth, fbHeight, simTime, delta, frame, &input.mouse))
		input.mouse.clicked = false
		frame++

		if input.saveShot {
			input.saveShot = false

			saveCapture(fbWidth, fbHeight)
		}

		fpsFrames++
		if now-fpsTime >= 0.5 {
			window.SetTitle(windowTitle(float64(fpsFrames)/(now-fpsTime), simTime, input.paused))
			fpsTime, fpsFrames = now, 0
		}

		window.SwapBuffers()
		glfw.PollEvents()
	}

	prog.delete()
}

// reloadProgram rebuilds the program when a watched file changed. If the new
// version fails to build, the error is logged and prog stays in use.
func reloadProgram(opt *options, watch *watcher, prog *program) *program {
	if !watch.changed() {
		return prog
	}

	next, body, err := loadProgram(opt)
	watch.add(body.files)

	if err != nil {
		fmt.Fprintf(os.Stderr, "[%s] reload failed, keeping previous program:\n%v\n", time.Now().Format("15:04:05"), err)

		return prog
	}

	prog.delete()

	fmt.Fprintf(os.Stderr, "[%s] reloaded %s\n", time.Now().Format("15:04:05"), opt.shader)

	return next
}

// liveUniforms returns the inputs for an interactive frame of the given size.
func liveUniforms(width, height int, simTime, delta float64, frame int32, mouse *mouseState) frameUniforms {
	now := time.Now()
	uniforms := frameUniforms{
		width: width, height: height,
		time: float32(simTime), timeDelta: float32(delta), frame: frame,
		mouse: mouse.uniform(),
		date: [4]float32{
			float32(now.Year()), float32(now.Month() - 1), float32(now.Day()),
			float32(now.Hour()*3600+now.Minute()*60+now.Second()) + float32(now.Nanosecond())/1e9,
		},
	}

	if delta > 0 {
		uniforms.frameRate = float32(1 / delta)
	}

	return uniforms
}

// saveCapture writes the current framebuffer to out/capture_<timestamp>.png.
func saveCapture(width, height int) {
	path := filepath.Join("out", "capture_"+time.Now().Format("20060102_150405")+".png")

	err := writePNG(path, readPixels(width, height))
	if err != nil {
		fmt.Fprintln(os.Stderr, "save:", err)
		return
	}

	fmt.Println("wrote", path)
}

func windowTitle(fps, simTime float64, paused bool) string {
	title := fmt.Sprintf("the-other-side  %.1f fps  %.2f ms  t=%.1f", fps, 1000/fps, simTime)
	if paused {
		title += "  [paused]"
	}

	return title
}

// watcher polls file modification times.
type watcher struct{ mtimes map[string]time.Time }

func newWatcher(files []string) *watcher {
	w := &watcher{mtimes: map[string]time.Time{}}
	w.add(files)

	return w
}

func (w *watcher) add(files []string) {
	for _, f := range files {
		w.mtimes[f] = mtime(f)
	}
}

// changed reports whether any watched file changed since the last call.
func (w *watcher) changed() bool {
	dirty := false

	for f, old := range w.mtimes {
		if m := mtime(f); !m.Equal(old) {
			w.mtimes[f] = m
			dirty = true
		}
	}

	return dirty
}

func mtime(path string) time.Time {
	st, err := os.Stat(path)
	if err != nil {
		return time.Time{}
	}

	return st.ModTime()
}
