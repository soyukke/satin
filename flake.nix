{
  description = "Satin native macOS terminal development environment";

  inputs = {
    nixpkgs.url = "nixpkgs";
    kizu.url = "github:kizu-lang/kizu";
  };

  outputs =
    { nixpkgs, kizu, ... }:
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
          font = pkgs.nerd-fonts.caskaydia-cove;
          kizuCompiler = kizu.packages.${system}.default;
          nativeShellHook = ''
            export SATIN_FONT="${font}/share/fonts/truetype/NerdFonts/CaskaydiaCove/CaskaydiaCoveNerdFontMono-Regular.ttf"
            echo "zig: $(zig version)"
            echo "kizu: $(kizu version)"
            echo "font: $SATIN_FONT"
          '';
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.actionlint
              pkgs.deadnix
              pkgs.git
              pkgs.gitleaks
              kizuCompiler
              pkgs.just
              pkgs.jq
              pkgs.markdownlint-cli2
              font
              pkgs.neovim
              pkgs.nixfmt
              pkgs.python3
              pkgs.ripgrep
              pkgs.shellcheck
              pkgs.shfmt
              pkgs.swift-format
              pkgs.tmux
              pkgs.typos
              pkgs.zizmor
              pkgs.zig_0_15
            ];

            shellHook = nativeShellHook;
          };

          # Keep macOS CI off the much larger formatting and policy-tool closure.
          ci-native = pkgs.mkShell {
            packages = [
              kizuCompiler
              pkgs.git
              pkgs.just
              pkgs.jq
              font
              pkgs.neovim
              pkgs.python3
              pkgs.ripgrep
              pkgs.tmux
              pkgs.zig_0_15
            ];

            shellHook = nativeShellHook;
          };

          # Release packaging needs neither editor tooling nor repository lints.
          ci-release = pkgs.mkShell {
            packages = [
              kizuCompiler
              pkgs.git
              pkgs.just
              pkgs.jq
              font
              pkgs.zig_0_15
            ];

            shellHook = nativeShellHook;
          };

          # These checks are platform-independent and run in parallel on Linux.
          ci-static = pkgs.mkShellNoCC {
            packages = [
              pkgs.actionlint
              pkgs.deadnix
              pkgs.git
              pkgs.just
              pkgs.markdownlint-cli2
              pkgs.nixfmt
              pkgs.ripgrep
              pkgs.shellcheck
              pkgs.shfmt
              pkgs.swift-format
              pkgs.typos
              pkgs.zizmor
              pkgs.zsh
            ];
          };
        }
      );
    };
}
