{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    mattware = {
      url = "github:mattrobenolt/nixpkgs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      flake-parts,
      nixpkgs,
      mattware,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      perSystem =
        { system, ... }:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ mattware.overlays.default ];
          };

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
          formatter = pkgs.nixfmt-tree;
          devShells.default = pkgs.mkShell {
            packages =
              with pkgs;
              [
                zig_0_16
                zls_0_16
                ziglint
                zigdoc
                zizmor
                pinact
                just
                python3
              ]
              ++ [ wrangler ];
          };
        };
    };
}
