{
    description = "A very basic flake";

    inputs = {
        nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
        flake-utils.url = "github:numtide/flake-utils";

        zig-overlay.url = "github:mitchellh/zig-overlay";
    };

    outputs = { self, nixpkgs, flake-utils, zig-overlay }: flake-utils.lib.eachDefaultSystem (system:
        let
            pkgs = import nixpkgs { inherit system; };
            zig = zig-overlay.packages.${system}."0.17.0";
        in {
            devShells.default = pkgs.mkShell {
                name = "zig-devshell";
                packages = [zig];
            };
        }
    );
}
