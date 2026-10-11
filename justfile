# The Other Side - GLSL night sea runner.
# Extra runner flags can be appended, e.g. `just shot 0,15 -D VIEW=3`.

# A stray /mnt/projekte/Code/.git (not a real repo) breaks Go's VCS stamping.
export GOFLAGS := "-buildvcs=false"

size := "1280x720"

# Window mode with hot reload (P = save PNG, Space = pause, Esc = quit)
default: run

# Install development dependencies (formatters and linters)
setup-deps:
    #!/bin/bash
    echo "Installing development dependencies..."

    # Install treefmt (required for formatting)
    command -v treefmt >/dev/null 2>&1 || { echo "Installing treefmt..."; curl -fsSL https://github.com/numtide/treefmt/releases/download/v2.1.1/treefmt_2.1.1_linux_amd64.tar.gz | sudo tar -C /usr/local/bin -xz treefmt; }

    # Install prettier (Node.js formatter)
    command -v prettier >/dev/null 2>&1 || { echo "Installing prettier..."; npm install -g prettier || echo "Prettier installation failed - npm not found. Please install Node.js/npm manually."; }

    # Install gofumpt (Go formatter)
    command -v gofumpt >/dev/null 2>&1 || { echo "Installing gofumpt..."; go install mvdan.cc/gofumpt@latest; }

    # Install gci (Go import formatter)
    command -v gci >/dev/null 2>&1 || { echo "Installing gci..."; go install github.com/daixiang0/gci@latest; }

    # Install shfmt (Shell formatter)
    command -v shfmt >/dev/null 2>&1 || { echo "Installing shfmt..."; go install mvdan.cc/sh/v3/cmd/shfmt@latest; }

    # Install golangci-lint (Go linter, v2 config format)
    command -v golangci-lint >/dev/null 2>&1 || { echo "Installing golangci-lint..."; curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/HEAD/install.sh | sh -s -- -b $(go env GOPATH)/bin; }

    # Note: shellcheck requires manual installation on most systems
    command -v shellcheck >/dev/null 2>&1 || echo "WARNING: shellcheck not found. Please install manually: apt-get install shellcheck (Ubuntu/Debian) or brew install shellcheck (macOS)"

    echo "Development dependencies installation complete!"
    echo "Note: Ensure $(go env GOPATH)/bin is in your PATH for Go-based tools"

#################################
# Format & lint
#################################

# Format code using treefmt
fmt:
    treefmt --allow-missing-formatter

# Run linter
lint:
    golangci-lint run --config ./.golangci.toml --timeout 2m

# Run linter (with fix)
lint-fix:
    golangci-lint run --config ./.golangci.toml --timeout 2m --fix

# Fix lint findings, then format
fix:
    just lint-fix
    just fmt

#################################
# Checks
#################################

# Run all checks
check: check-formatted lint check-tidy check-build

# Check if code is formatted (no git repo here, so treefmt checks itself)
check-formatted:
    treefmt --allow-missing-formatter --fail-on-change

# Check if go.mod is tidy
check-tidy:
    go mod tidy -diff

# Build and vet
check-build:
    go build -o /dev/null .
    go vet ./...

#################################
# Shader runner
#################################

# Window mode with hot reload (P = save PNG, Space = pause, Esc = quit)
run *args:
    go run . -size {{size}} {{args}}

# Offscreen shots into out/ at fixed times
shot times="0,15" *args:
    go run . -size {{size}} -shot out/shot.png -times {{times}} {{args}}

# Shots plus side-by-side montages against another image, e.g. an earlier render (out/*_cmp.png)
compare ref times="0,15" *args:
    go run . -size {{size}} -shot out/shot.png -times {{times}} -compare {{ref}} {{args}}

# Benchmark at 1280x720 and 1920x1080
bench dur="3s" *args:
    go run . -bench {{dur}} -size 1280x720 {{args}}
    go run . -bench {{dur}} -size 1920x1080 {{args}}

# Single-file Shadertoy export, verified by rendering it back
bundle *args:
    go run . -bundle out/shadertoy.glsl {{args}}
    go run . -shader out/shadertoy.glsl -shot out/shadertoy_check.png -time 15 -size {{size}}
