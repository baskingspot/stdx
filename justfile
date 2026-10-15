# stdx: shared std-lib extensions. README.md describes the modules;
# AGENTS.md holds the working conventions.

default: test

# Build the site into zig-out/site/: the guide (Zola, from docs/) at the
# root and the API reference (the wasm viewer `zig std` uses) under /api/.
# Open zig-out/site/index.html through `just doc-serve`, not file://.
doc:
    zig build docs
    zola --root docs build --output-dir zig-out/site --force
    mkdir -p zig-out/site/api
    cp -R zig-out/zig-docs/. zig-out/site/api/

# Edit the guide with live reload (http://127.0.0.1:1111). No API reference
# here; `doc-serve` has the whole site.
guide:
    zola --root docs serve

# Serve the built site at http://127.0.0.1:PORT (default 8000; override with
# an argument or the PORT env var)
doc-serve port=env("PORT", "8000"): doc
    python3 -m http.server -d zig-out/site -b 127.0.0.1 "{{ port }}"

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

# Lint: ziglint, Zig, markdown and CSS, and justfile formatting
lint:
    ziglint
    zig fmt --check src docs/examples build.zig
    oxfmt --check README.md docs/content docs/static
    just --fmt --check

# Format everything lint checks
fmt:
    zig fmt src docs/examples build.zig
    oxfmt README.md docs/content docs/static
    just --fmt

# Everything CI runs
ci: test test-release-safe test-release-fast lint doc

# Run benchmarks (e.g. `just bench -Doptimize=ReleaseFast -- --benchtime=250ms --filter=Swiss`)
bench *ARGS:
    zig build bench {{ ARGS }}

# Zig 0.16: --fuzz takes an iteration budget with a K/M/G suffix, not a
# duration. ReleaseSafe forces the LLVM backend, dodging the 0.16.0
# self-hosted-backend bug in Debug fuzz mode (ziglang/zig#30655).
# Run the fuzzer with an iteration budget (e.g. just fuzz 50M)
fuzz LIMIT="10M":
    zig build test -Doptimize=ReleaseSafe --fuzz={{ LIMIT }}
