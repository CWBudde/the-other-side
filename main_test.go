package main

import (
	"os"
	"path/filepath"
	"slices"
	"testing"
)

func TestShotTimes(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name    string
		start   float64
		list    string
		fps     float64
		frames  int
		want    []float64
		wantErr bool
	}{
		{name: "start only", start: 15, fps: 30, want: []float64{15}},
		{name: "list", list: "0, 10,30.5", fps: 30, want: []float64{0, 10, 30.5}},
		{name: "frames", start: 1, fps: 4, frames: 3, want: []float64{1, 1.25, 1.5}},
		{name: "bad list entry", list: "0,x", fps: 30, wantErr: true},
		{name: "frames with list", list: "0", fps: 30, frames: 2, wantErr: true},
		{name: "frames without fps", fps: 0, frames: 2, wantErr: true},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			got, err := shotTimes(tc.start, tc.list, tc.fps, tc.frames)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("expected an error, got %v", got)
				}

				return
			}

			if err != nil {
				t.Fatal(err)
			}

			if !slices.Equal(got, tc.want) {
				t.Errorf("shotTimes = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestShotPath(t *testing.T) {
	t.Parallel()

	const shot = "out/shot.png"

	tests := []struct {
		name string
		opt  options
		i    int
		time float64
		want string
	}{
		{"single", options{shot: shot, times: []float64{15}}, 0, 15, shot},
		{"times", options{shot: shot, times: []float64{0, 7.25}}, 1, 7.25, "out/shot_t07.2.png"},
		{"frames", options{shot: "out/clip/f.png", frames: 300}, 42, 1.4, "out/clip/f_00042.png"},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			if got := shotPath(&tc.opt, tc.i, tc.time); got != tc.want {
				t.Errorf("shotPath = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestMouseUniform(t *testing.T) {
	t.Parallel()

	pos, click := [2]float32{5, 6}, [2]float32{1, 2}

	tests := []struct {
		name  string
		mouse mouseState
		want  [4]float32
	}{
		{"clicked", mouseState{pos: pos, click: click, down: true, clicked: true}, [4]float32{5, 6, 1, 2}},
		{"dragging", mouseState{pos: pos, click: click, down: true}, [4]float32{5, 6, 1, -2}},
		{"released", mouseState{pos: pos, click: click}, [4]float32{5, 6, -1, -2}},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			if got := tc.mouse.uniform(); got != tc.want {
				t.Errorf("uniform() = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestBufferPath(t *testing.T) {
	t.Parallel()

	withBuffer := writeFiles(t, map[string]string{mainShader: "", bufferFile: ""})
	without := writeFiles(t, map[string]string{mainShader: ""})

	tests := []struct {
		name, shader, bufA, want string
	}{
		{"auto found", filepath.Join(withBuffer, mainShader), bufAuto, filepath.Join(withBuffer, bufferFile)},
		{"auto missing", filepath.Join(without, mainShader), bufAuto, ""},
		{"disabled", filepath.Join(withBuffer, mainShader), bufNone, ""},
		{"empty", filepath.Join(withBuffer, mainShader), "", ""},
		{"explicit", filepath.Join(without, mainShader), "other.glsl", "other.glsl"},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			if got := bufferPath(&options{shader: tc.shader, bufA: tc.bufA}); got != tc.want {
				t.Errorf("bufferPath = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestWatcherChanged(t *testing.T) {
	t.Parallel()

	dir := writeFiles(t, map[string]string{"a.glsl": "a"})
	path := filepath.Join(dir, "a.glsl")

	w := newWatcher([]string{path})
	if w.changed() {
		t.Fatal("unchanged file reported as changed")
	}

	// Bump the mtime explicitly; a rewrite may land in the same tick.
	stat, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}

	later := stat.ModTime().Add(1e9)

	err = os.Chtimes(path, later, later)
	if err != nil {
		t.Fatal(err)
	}

	if !w.changed() {
		t.Fatal("modified file not reported")
	}

	if w.changed() {
		t.Fatal("change reported twice")
	}
}
