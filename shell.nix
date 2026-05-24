{
  mkShell,
  pkg-config,
  rustc,
  clippy,
  rust-analyzer-unwrapped,
  tombi,
  rustPlatform,
  cargo,
  rustfmt,
}:
mkShell {
  packages = [
    pkg-config
    clippy
    rustc
    rust-analyzer-unwrapped
    (rustfmt.override { asNightly = true; })
    tombi
    cargo
  ];
  env.RUST_SRC_PATH = rustPlatform.rustLibSrc;
}
