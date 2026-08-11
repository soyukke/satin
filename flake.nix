{
  description = "Satin native macOS terminal development environment";

  inputs = {
    nixpkgs.url = "nixpkgs";
  };

  outputs =
    { nixpkgs, ... }:
    let
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.actionlint
              pkgs.cargo
              pkgs.cargo-about
              pkgs.cargo-audit
              pkgs.clippy
              pkgs.deadnix
              pkgs.git
              pkgs.gitleaks
              pkgs.just
              pkgs.jq
              pkgs.markdownlint-cli2
              pkgs.nerd-fonts.caskaydia-cove
              pkgs.neovim
              pkgs.nixfmt
              pkgs.python3
              pkgs.ripgrep
              pkgs.rust-analyzer
              pkgs.rustc
              pkgs.rustfmt
              pkgs.shellcheck
              pkgs.shfmt
              pkgs.swift-format
              pkgs.typos
              pkgs.zizmor
              pkgs.zig_0_15
            ];

            shellHook = ''
              export SATIN_FONT="${pkgs.nerd-fonts.caskaydia-cove}/share/fonts/truetype/NerdFonts/CaskaydiaCove/CaskaydiaCoveNerdFontMono-Regular.ttf"
              echo "zig: $(zig version)"
              echo "rustc: $(rustc --version)"
              echo "font: $SATIN_FONT"
            '';
          };
        }
      );
    };
}
