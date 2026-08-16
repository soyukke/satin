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
          font = pkgs.nerd-fonts.caskaydia-cove;
          nativeShellHook = ''
            export SATIN_FONT="${font}/share/fonts/truetype/NerdFonts/CaskaydiaCove/CaskaydiaCoveNerdFontMono-Regular.ttf"
            echo "zig: $(zig version)"
            echo "rustc: $(rustc --version)"
            echo "font: $SATIN_FONT"
          '';
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
              font
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
              pkgs.cargo
              pkgs.cargo-about
              pkgs.clippy
              pkgs.git
              pkgs.just
              pkgs.jq
              font
              pkgs.neovim
              pkgs.python3
              pkgs.ripgrep
              pkgs.rustc
              pkgs.tmux
              pkgs.zig_0_15
            ];

            shellHook = nativeShellHook;
          };

          # Release packaging needs neither editor tooling nor repository lints.
          ci-release = pkgs.mkShell {
            packages = [
              pkgs.cargo
              pkgs.cargo-about
              pkgs.git
              pkgs.just
              pkgs.jq
              font
              pkgs.rustc
              pkgs.zig_0_15
            ];

            shellHook = nativeShellHook;
          };

          # These checks are platform-independent and run in parallel on Linux.
          ci-static = pkgs.mkShellNoCC {
            packages = [
              pkgs.actionlint
              pkgs.cargo
              pkgs.deadnix
              pkgs.git
              pkgs.just
              pkgs.markdownlint-cli2
              pkgs.nixfmt
              pkgs.ripgrep
              pkgs.rustfmt
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
