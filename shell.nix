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
}
