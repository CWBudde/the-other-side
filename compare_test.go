package main

import (
	"image"
	"image/color"
	"testing"
)

func uniformImage(w, h int, c color.RGBA) *image.RGBA {
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := range h {
		for x := range w {
			img.SetRGBA(x, y, c)
		}
	}

	return img
}

func TestResizeKeepsUniformColor(t *testing.T) {
	t.Parallel()

	want := color.RGBA{10, 120, 230, 255}
	src := uniformImage(7, 5, want)

	for _, size := range [][2]int{{7, 5}, {3, 2}, {20, 13}} {
		out := resize(src, size[0], size[1])
		if b := out.Bounds(); b.Dx() != size[0] || b.Dy() != size[1] {
			t.Fatalf("resize to %v: bounds %v", size, b)
		}

		for y := range size[1] {
			for x := range size[0] {
				if got := out.RGBAAt(x, y); got != want {
					t.Fatalf("resize to %v: pixel (%d,%d) = %v, want %v", size, x, y, got, want)
				}
			}
		}
	}
}

func TestResizeBoxFiltersOnDownscale(t *testing.T) {
	t.Parallel()

	// A 2x1 black/white image shrunk to 1x1 must average to mid gray.
	src := image.NewRGBA(image.Rect(0, 0, 2, 1))
	src.SetRGBA(0, 0, color.RGBA{0, 0, 0, 255})
	src.SetRGBA(1, 0, color.RGBA{255, 255, 255, 255})

	got := resize(src, 1, 1).RGBAAt(0, 0)
	if want := (color.RGBA{128, 128, 128, 255}); got != want {
		t.Errorf("pixel = %v, want %v", got, want)
	}
}

func TestMontage(t *testing.T) {
	t.Parallel()

	red := color.RGBA{255, 0, 0, 255}
	blue := color.RGBA{0, 0, 255, 255}
	render := uniformImage(40, 20, red)
	ref := uniformImage(20, 5, blue) // scaled to 80x20

	out := montage(render, ref)
	if b := out.Bounds(); b.Dx() != 40+montageGap+80 || b.Dy() != 20 {
		t.Fatalf("bounds = %v", b)
	}

	checks := []struct {
		x    int
		want color.RGBA
	}{
		{0, red},
		{39, red},
		{40, color.RGBA{16, 16, 16, 255}},
		{40 + montageGap, blue},
		{out.Bounds().Dx() - 1, blue},
	}
	for _, c := range checks {
		if got := out.RGBAAt(c.x, 10); got != c.want {
			t.Errorf("pixel x=%d = %v, want %v", c.x, got, c.want)
		}
	}
}

func TestCompareName(t *testing.T) {
	t.Parallel()

	if got, want := compareName("out/full_t10.0.png"), "out/full_t10.0_cmp.png"; got != want {
		t.Errorf("compareName = %q, want %q", got, want)
	}
}
