{
  inputs.nixpkgs.url = "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.xz";

  outputs =
    {
      nixpkgs,
      self,
    }:
    let
      inherit (nixpkgs) lib;
      systems = lib.systems.flakeExposed;
      eachSystem = lib.genAttrs systems;
      pkgsFor = nixpkgs.legacyPackages;

      rev = self.shortRev or self.dirtyShortRev or "dirty";
    in
    {
      devShells = eachSystem (system: {
        default = pkgsFor.${system}.callPackage ./shell.nix { };
      });

      packages = eachSystem (system: {
        npr = pkgsFor.${system}.callPackage ./package.nix {

          inherit rev;
        };
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
