# stdx: shared std-lib extensions. README.md describes the modules;
# AGENTS.md holds the working conventions.

[private]
default:
    @just --list

[doc("Build the site into zig-out/site/stdx/: the guide (Zola, from docs/) and the API reference (docgen JSON, rendered by the theme's api.html) under api/. The router in baskingspot/site serves /stdx/... from it")]
[group("docs")]
doc: api
    baskingspot-docs build stdx

[doc("Edit the guide with live reload (http://127.0.0.1:1111), API reference included")]
[group("docs")]
guide: api
    baskingspot-docs serve stdx

# The API reference data. docgen comes from the baskingspot flake's docs shell,
# so this is not a Zig build dependency.
[private]
api:
    docgen --root src/root.zig --title stdx --repo-url https://github.com/baskingspot/stdx --rev main --format json --out docs/data

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

[doc("Run the fuzzer with an iteration budget, for example `just fuzz 50M`. Uses the built-in test runner, which testingx does not replace in fuzz mode. ReleaseSafe forces the LLVM backend, dodging the 0.16.0 self-hosted-backend bug in Debug fuzz mode (ziglang/zig#30655)")]
[group("test")]
fuzz LIMIT="10M":
    zig build fuzz -Doptimize=ReleaseSafe --fuzz={{ LIMIT }}

[doc("Lint: ziglint, Zig, Nix, Markdown and CSS, the workflows, and justfile formatting")]
[group("lint")]
lint:
    ziglint
    zig fmt --check src docs/examples build.zig build.zig.zon
    nix fmt -- --ci
    oxfmt --check README.md AGENTS.md IDEAS.md THIRD_PARTY.md .pi/agents docs/VOICE.md docs/content docs/static .github wrangler.jsonc .oxfmtrc.jsonc docs/config.toml
    actionlint
    zizmor .
    just --fmt --check

[doc("Format everything lint checks")]
[group("lint")]
fmt:
    zig fmt src docs/examples build.zig build.zig.zon
    nix fmt
    oxfmt README.md AGENTS.md IDEAS.md THIRD_PARTY.md .pi/agents docs/VOICE.md docs/content docs/static .github wrangler.jsonc .oxfmtrc.jsonc docs/config.toml
    just --fmt

[doc("Everything CI runs: the unit tests, lint, and the site build")]
[group("ci")]
ci: test test-release-safe test-release-fast lint doc

[doc("Run benchmarks (ReleaseFast by default); args pass to the binary: just bench --benchtime=250ms --filter=Swiss")]
[group("bench")]
bench *ARGS:
    zig build bench -- {{ ARGS }}

[doc("Run every benchmark once: proves the suite builds and runs, without measuring")]
[group("bench")]
bench-smoke:
    zig build bench -- --benchtime=8x --count=1 --no-env
