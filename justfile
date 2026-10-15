# stdx: shared std-lib extensions. README.md describes the modules;
# AGENTS.md holds the working conventions.

default: test

# Render API docs into zig-out/zig-docs/ (the wasm viewer `zig std`
# uses; open zig-out/zig-docs/index.html)
doc:
    zig build docs

# Serve the rendered docs at http://127.0.0.1:PORT (default 8000;
# override with an argument or the PORT env var)
doc-serve port=env("PORT", "8000"): doc
    python3 -m http.server -d zig-out/zig-docs -b 127.0.0.1 "{{ port }}"

# Deploy the rendered docs to Cloudflare as an assets-only Worker (config in
# wrangler.jsonc). Needs CLOUDFLARE_API_TOKEN in the environment, plus
# CLOUDFLARE_ACCOUNT_ID if the token can see more than one account —
doc-deploy: doc
    wrangler deploy

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

# Run benchmarks (e.g. `just bench -Doptimize=ReleaseFast -- --benchtime=250ms --filter=Swiss`)
bench *ARGS:
    zig build bench {{ ARGS }}
