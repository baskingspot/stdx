# stdx: shared std-lib extensions. README.md describes the modules;
# AGENTS.md holds the working conventions.

default: test

# Render API docs into zig-out/zig-docs/ (the wasm viewer `zig std`
# uses; open zig-out/zig-docs/index.html)
doc:
    zig build docs

# Serve the rendered docs at http://localhost:8000
serve: doc
    python3 -m http.server -d zig-out/zig-docs 8000

# Unit tests (Debug)
test:
    zig build test --summary all

# Unit tests (ReleaseSafe) — the option matrix: lazy analysis hides code that
# only instantiates in release modes
test-release-safe:
    zig build test -Doptimize=ReleaseSafe --summary all

# Unit tests (ReleaseFast)
test-release-fast:
    zig build test -Doptimize=ReleaseFast --summary all

# Lint: ziglint, Zig formatting, justfile formatting
lint:
    ziglint
    zig fmt --check src build.zig
    just --fmt --check

# Everything CI runs
ci: test test-release-safe test-release-fast lint
