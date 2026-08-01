# Build commands for mako

set positional-arguments

# Default recipe: build + run (forwards args after `just run ...`)
default: run

# Debug build
build:
    swift build -c debug

# Release build
build-release:
    swift build -c release

# Run mako from the existing debug build, forwarding args (run `just build` first)
run *ARGS:
    ./.build/debug/mako "$@"

# Run tests
test:
    swift test

# Clean build artifacts
clean:
    rm -rf .build
