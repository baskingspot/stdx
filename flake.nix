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

          # Cloudflare's `cf` CLI (open beta) as a thin wrapper: exec npx with
          # a pinned version. The npm dist is fully bundled, so npx fetches a
          # single package and runs it. The flake pins the version; npm owns
          # the bits. Deploy stays on wrangler until cf leaves beta.
          cfVersion = "1.0.0-beta.16";
          cf-cli = pkgs.writeShellApplication {
            name = "cf";
            runtimeInputs = [ pkgs.nodejs_22 ];
            text = ''exec npx --yes "cf@${cfVersion}" "$@"'';
          };
        in
        {
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
                wrangler
              ]
              ++ [ cf-cli ];
          };
        };
    };
}
