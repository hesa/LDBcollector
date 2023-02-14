{
  description = "ldbcollector in rust";

  inputs = {
    nixpkgs.url      = "github:NixOS/nixpkgs/nixos-unstable";
    rust-overlay.url = "github:oxalica/rust-overlay";
    flake-utils.url  = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, rust-overlay, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        overlays = [ (import rust-overlay) ];
        pkgs = import nixpkgs {
          inherit system overlays;
        };
      in
      with pkgs;
      {
        devShells.default = mkShell {
          packages = with pkgs; [ 
            cargo-generate
            wasm-bindgen-cli
            wasm
            wasm-pack
            wasmer
          ];
          buildInputs = [
            openssl
            pkg-config
            rust-bin.beta.latest.default
            nodejs
          ];

          shellHook = ''
            export RUST_LOG=debug
          '';
        };
      }
    );
}
