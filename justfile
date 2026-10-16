# stdx: shared std-lib extensions. README.md describes the modules;
# AGENTS.md holds the working conventions.

[private]
default:
    @just --list

[doc("Build the site into zig-out/site/stdx/: the guide (Zola, from docs/) and the API reference (the wasm viewer `zig std` uses) under api/. The router in baskingspot/site serves /stdx/... from it")]
[group("docs")]
doc:
    zig build docs
    baskingspot-docs build stdx

[doc("Edit the guide with live reload (http://127.0.0.1:1111), API reference included")]
[group("docs")]
guide:
    zig build docs
    baskingspot-docs serve stdx

[doc("Deploy the rendered docs to Cloudflare as an assets-only Worker (config in wrangler.jsonc). Needs CLOUDFLARE_API_TOKEN in the environment, plus CLOUDFLARE_ACCOUNT_ID if the token can see more than one account")]
[group("docs")]
doc-deploy: doc
    wrangler deploy

[doc("Unit tests (Debug)")]
[group("test")]
test:
    zig build test --summary all

[doc("Unit tests (ReleaseSafe): the option matrix, because lazy analysis hides code that only instantiates in release modes")]
[group("test")]
test-release-safe:
    zig build test -Doptimize=ReleaseSafe --summary all

[doc("Unit tests (ReleaseFast)")]
[group("test")]
test-release-fast:
    zig build test -Doptimize=ReleaseFast --summary all

[doc("Run the fuzzer with an iteration budget, for example `just fuzz 50M`. ReleaseSafe forces the LLVM backend, dodging the 0.16.0 self-hosted-backend bug in Debug fuzz mode (ziglang/zig#30655)")]
[group("test")]
fuzz LIMIT="10M":
    zig build test -Doptimize=ReleaseSafe --fuzz={{ LIMIT }}

[doc("Lint: ziglint, Zig, Nix, Markdown and CSS, the workflows, and justfile formatting")]
[group("lint")]
lint:
    ziglint
    zig fmt --check src docs/examples build.zig
    nix fmt -- --ci
    oxfmt --check README.md AGENTS.md docs/VOICE.md docs/content docs/static .github wrangler.jsonc .oxfmtrc.jsonc docs/config.toml
    actionlint
    zizmor .
    just --fmt --check

[doc("Format everything lint checks")]
[group("lint")]
fmt:
    zig fmt src docs/examples build.zig
    nix fmt
    oxfmt README.md AGENTS.md docs/VOICE.md docs/content docs/static .github wrangler.jsonc .oxfmtrc.jsonc docs/config.toml
    just --fmt

[doc("Everything CI runs: the unit tests, lint, and the site build")]
[group("ci")]
ci: test test-release-safe test-release-fast lint doc

[doc("Run benchmarks (e.g. `just bench -Doptimize=ReleaseFast -- --benchtime=250ms --filter=Swiss`)")]
[group("bench")]
bench *ARGS:
    zig build bench {{ ARGS }}

[doc("Fails on purpose, for a CI experiment")]
[group("ci")]
boom:
    exit 1
