{
  lib,
  rustPlatform,
  rev ? "dirty",
}:
let
  cargoToml = lib.importTOML ./Cargo.toml;
in
rustPlatform.buildRustPackage {
  pname = "npr";
  version = "${cargoToml.package.version}-${rev}";

  src = ./.;

  cargoLock.lockFile = ./Cargo.lock;
}
