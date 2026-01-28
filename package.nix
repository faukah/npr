{
  stdenv,
  zig,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "npr";
  version = "0.1.0";

  src = ./.;

  nativeBuildInputs = [
    zig
  ];

  zigBuildFlags = [
    "-Doptimize=ReleaseFast"
  ];
})
