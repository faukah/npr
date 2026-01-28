{
  mkShellNoCC,
  zig,
  zls,
}:
mkShellNoCC {
  name = "zig";

  packages = [
    zig
    zls
  ];

  shellHook = ''
    # Remove once https://github.com/NixOS/nixpkgs/issues/270415
    # is fixed.
    unset ZIG_GLOBAL_CACHE_DIR
  '';
}
