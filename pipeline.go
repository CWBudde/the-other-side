package main

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/go-gl/gl/v4.1-core/gl"
)

// bufferFile is the Buffer A shader the runner picks up beside the main
// shader when -bufa is "auto".
const bufferFile = "buffer_a.glsl"

// -bufa modes besides an explicit path.
const (
	bufAuto = "auto"
	bufNone = "none"
)

// pipeline is the Image pass, optionally fed by a Buffer A pass. Buffer A
// renders into a half-float texture with a mip chain that is bound to
// iChannel0 of the Image pass, like a Shadertoy Buffer A on iChannel0 with
// the "mipmap" filter and clamped edges.
type pipeline struct {
	image, bufA *program
	target      *fbo // Buffer A output, sized to the frame on demand
}

// loadPipeline builds the Image pass and, if configured, Buffer A. It also
// returns all source files for the hot-reload watcher, even on errors.
func loadPipeline(opt *options) (*pipeline, []string, error) {
	image, files, err := loadPass(opt.shader, opt.defines)
	if err != nil {
		return nil, files, err
	}

	pipe := &pipeline{image: image}

	bufPath := bufferPath(opt)
	if bufPath == "" {
		return pipe, files, nil
	}

	bufA, bufFiles, err := loadPass(bufPath, opt.defines)
	files = append(files, bufFiles...)

	if err != nil {
		pipe.delete()
		return nil, files, err
	}

	pipe.bufA = bufA

	return pipe, files, nil
}

func loadPass(path string, defs defineList) (*program, []string, error) {
	body, err := loadShader(path)
	if err != nil {
		return nil, body.files, err
	}

	prog, err := buildProgram(body, defs)

	return prog, body.files, err
}

// bufferPath resolves -bufa: "auto" is buffer_a.glsl beside the main shader
// if that file exists, "" or "none" disables the buffer pass.
func bufferPath(opt *options) string {
	switch opt.bufA {
	case "", bufNone:
		return ""
	case bufAuto:
		path := filepath.Join(filepath.Dir(opt.shader), bufferFile)

		_, err := os.Stat(path)
		if err != nil {
			return ""
		}

		return path
	default:
		return opt.bufA
	}
}

func (p *pipeline) delete() {
	if p == nil {
		return
	}

	p.image.delete()
	p.bufA.delete()

	if p.target != nil {
		p.target.delete()
	}
}

// draw renders one frame into the currently bound framebuffer. A nil
// pipeline (failed initial build) just clears it.
func (p *pipeline) draw(screen *quad, uni frameUniforms) error {
	if p == nil {
		screen.draw(nil, uni)
		return nil
	}

	if p.bufA == nil {
		screen.draw(p.image, uni)
		return nil
	}

	// The caller's framebuffer, restored for the Image pass.
	var bound int32
	gl.GetIntegerv(gl.DRAW_FRAMEBUFFER_BINDING, &bound)
	dst := uint32(max(bound, 0))

	if p.target == nil || p.target.width != uni.width || p.target.height != uni.height {
		if p.target != nil {
			p.target.delete()
		}

		target, err := newBufferFBO(uni.width, uni.height)
		if err != nil {
			p.target = nil
			return fmt.Errorf("buffer A: %w", err)
		}

		p.target = target
	}

	// Buffer A must not see its own texture.
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, 0)
	gl.BindFramebuffer(gl.FRAMEBUFFER, p.target.id)
	screen.draw(p.bufA, uni)

	gl.BindTexture(gl.TEXTURE_2D, p.target.tex)
	gl.GenerateMipmap(gl.TEXTURE_2D)
	gl.BindFramebuffer(gl.FRAMEBUFFER, dst)

	uni.channel0 = [2]int{uni.width, uni.height}
	screen.draw(p.image, uni)
	gl.BindTexture(gl.TEXTURE_2D, 0)

	return nil
}
