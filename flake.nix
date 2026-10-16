{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts.follows = "baskingspot/flake-parts";
    baskingspot = {
      url = "github:baskingspot/nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      # imports and inputsFrom below mirror each other, except the toolchain
      # version: pick that once, in the import.
      imports = with inputs.baskingspot.flakeModules; [
        base
        zig."0.16"
      ];

      perSystem =
        { pkgs, config, ... }:
        let
          # Wrangler as a thin wrapper: exec npx with a pinned version; the
          # flake pins the version, npm owns the bits. min-release-age is
          # overridden per-tool so day-zero wrangler releases stay installable
          # (the global npmrc supply-chain guard still covers everything
          # else). `cf` was tried here and dropped: `cf deploy` requires a
          # JS/Python/Rust manifest (package.json et al) to pick a build
          # tool, which this repo will never have.
          wranglerVersion = "4.150.0";
          wrangler = pkgs.writeShellApplication {
            name = "wrangler";
            runtimeEnv = {
              NPM_CONFIG_MIN_RELEASE_AGE = "0";
            };
            text = ''exec ${pkgs.nodejs_24}/bin/npx --yes "wrangler@${wranglerVersion}" "$@"'';
          };
        in
        {
          devShells.default = pkgs.mkShell {
            inputsFrom = with config.devShells; [
              base
              zig
            ];

            packages =
              with pkgs;
              [
                oxfmt
              ]
              # perf for the benchmark passes: hardware counters on the
              # hot paths. Linux only; darwin has nothing equivalent.
              ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ perf ];
          };

          # Just what building and deploying the site needs. The justfile's
          # doc recipes enter this shell themselves, so `just doc` works from
          # the default shell too. CI uses it directly.
          devShells.docs = pkgs.mkShell {
            packages =
              with pkgs;
              [
                zig_0_16
                zola
                just
                svgo
              ]
              ++ [ wrangler ];
            # Tells the justfile it is already here, so it does not nest.
            env.STDX_DOCS_SHELL = "1";
          };
        };
    };
}
