{
  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.xz";
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    zls = {
      url = "github:zigtools/zls";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      zig-overlay,
      zls,
      self,
    }:
    let
      inherit (nixpkgs) lib;
      systems = lib.systems.flakeExposed;
      eachSystem = lib.genAttrs systems;
      pkgsFor = nixpkgs.legacyPackages;
    in
    {
      devShells = eachSystem (system: {
        default = pkgsFor.${system}.callPackage ./shell.nix {
          zig = (zig-overlay.packages.${system}.master);
          inherit (zls.packages.${system}) zls;
        };
      });

      packages = eachSystem (system: {
        npr = pkgsFor.${system}.callPackage ./package.nix { };
        default = self.packages.${system}.npr;
      });

      apps = eachSystem (system: {
        npr = {
          type = "app";
          program = "${self.packages.${system}.npr}/bin/npr";
        };
        default = self.apps.${system}.npr;
      });
    };
}
