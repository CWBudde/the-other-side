package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const mainShader = "main.glsl"

// writeFiles creates files (relative path -> content) below a temp dir and
// returns the dir.
func writeFiles(t *testing.T, files map[string]string) string {
	t.Helper()

	dir := t.TempDir()
	for name, content := range files {
		path := filepath.Join(dir, name)

		err := os.MkdirAll(filepath.Dir(path), 0o755)
		if err != nil {
			t.Fatal(err)
		}

		err = os.WriteFile(path, []byte(content), 0o600)
		if err != nil {
			t.Fatal(err)
		}
	}

	return dir
}

func TestLoadShaderInlinesIncludes(t *testing.T) {
	t.Parallel()

	dir := writeFiles(t, map[string]string{
		mainShader:      "#include \"lib/a.glsl\"\r\nvoid main() {}\r\n",
		"lib/a.glsl":    "// a\n  #  include \"b.glsl\"\n",
		"lib/b.glsl":    "// b\n#include \"a.glsl\"\n", // cycle back to a
		"unrelated.txt": "",
	})

	src, err := loadShader(filepath.Join(dir, mainShader))
	if err != nil {
		t.Fatal(err)
	}

	want := "// a\n// b\nvoid main() {}\n"
	if got := src.String(); got != want {
		t.Errorf("source = %q, want %q", got, want)
	}

	main := filepath.Join(dir, mainShader)
	libA := filepath.Join(dir, "lib", "a.glsl")
	libB := filepath.Join(dir, "lib", "b.glsl")

	wantOrigins := []origin{{libA, 1}, {libB, 1}, {main, 2}}
	for i, o := range wantOrigins {
		if src.origins[i] != o {
			t.Errorf("origins[%d] = %v, want %v", i, src.origins[i], o)
		}
	}

	wantFiles := []string{main, libA, libB}
	if strings.Join(src.files, ",") != strings.Join(wantFiles, ",") {
		t.Errorf("files = %v, want %v", src.files, wantFiles)
	}
}

func TestLoadShaderErrors(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name  string
		files map[string]string
		want  string
	}{
		{
			name:  "missing include",
			files: map[string]string{mainShader: "x\n#include \"nope.glsl\"\n"},
			want:  `main.glsl:2: include "nope.glsl"`,
		},
		{
			name:  "escape root",
			files: map[string]string{mainShader: "#include \"../outside.glsl\"\n"},
			want:  `include "../outside.glsl"`,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			dir := writeFiles(t, tc.files)

			src, err := loadShader(filepath.Join(dir, mainShader))
			if err == nil {
				t.Fatal("expected an error")
			}

			if !strings.Contains(err.Error(), tc.want) {
				t.Errorf("error %q does not contain %q", err, tc.want)
			}

			if len(src.files) == 0 {
				t.Error("files read so far should be reported for the watcher")
			}
		})
	}
}

// TestLoadShaderRepoShaders makes sure the shipped shaders resolve all
// includes (compiling them needs a GL context, which CI does not have).
func TestLoadShaderRepoShaders(t *testing.T) {
	t.Parallel()

	for _, name := range []string{mainShader, bufferFile} {
		src, err := loadShader(filepath.Join("shaders", name))
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}

		if !strings.Contains(src.String(), "mainImage") {
			t.Errorf("%s: no mainImage found", name)
		}
	}
}

func TestDefineListSet(t *testing.T) {
	t.Parallel()

	var defs defineList
	for _, arg := range []string{"VIEW=3", "DEBUG", "EXPR=a=b"} {
		err := defs.Set(arg)
		if err != nil {
			t.Fatalf("Set(%q): %v", arg, err)
		}
	}

	if got, want := defs.String(), "VIEW=3,DEBUG=1,EXPR=a=b"; got != want {
		t.Errorf("String() = %q, want %q", got, want)
	}

	if got, want := defs.source().String(), "#define VIEW 3\n#define DEBUG 1\n#define EXPR a=b\n"; got != want {
		t.Errorf("source() = %q, want %q", got, want)
	}

	for _, arg := range []string{"", "=1", "A B=1", "A\tB"} {
		err := defs.Set(arg)
		if err == nil {
			t.Errorf("Set(%q) should fail", arg)
		}
	}
}

func TestRemapLog(t *testing.T) {
	t.Parallel()

	src := &source{}
	src.addGenerated("#version 330\nprefix", "<prefix>")
	src.add("float x;", origin{file: "water.glsl", line: 17})

	tests := []struct {
		name, log, want string
	}{
		{"mesa", "0:3(5): error: bad", "water.glsl:17:5: error: bad"},
		{"nvidia", "0(3) : error C0000: bad", "water.glsl:17: error C0000: bad"},
		{"plain", "ERROR: 0:3: bad", "ERROR: water.glsl:17: bad"},
		{"generated line", "0:2(1): error", "<prefix>:1: error"},
		{"out of range", "0:9(1): error", "?:9:1: error"},
		{"trailing junk", "0:3(1): error\n\x00", "water.glsl:17:1: error"},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			if got := src.remapLog(tc.log); got != tc.want {
				t.Errorf("remapLog(%q) = %q, want %q", tc.log, got, tc.want)
			}
		})
	}
}

func TestBundle(t *testing.T) {
	t.Parallel()

	body := &source{}
	body.add("// common", origin{file: "common.glsl", line: 1})
	body.add("void mainImage() {}", origin{file: mainShader, line: 2})
	body.add("// end", origin{file: mainShader, line: 3})

	got := bundle(body, defineList{{"VIEW", "3"}}, "shaders/main.glsl", "Paste into Image.")

	want := "// Bundled from shaders/main.glsl by the-other-side runner. Paste into Image.\n" +
		"#define VIEW 3\n" +
		"\n// ---- common.glsl ----\n// common\n" +
		"\n// ---- main.glsl ----\nvoid mainImage() {}\n// end\n"
	if got != want {
		t.Errorf("bundle =\n%s\nwant\n%s", got, want)
	}
}
