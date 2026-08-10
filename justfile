set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    @just --list

# Enter the Nix development shell.
shell:
    @nix develop

# Show tool versions from the flake shell.
doctor:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then exec nix develop --command just doctor; else echo "zig:  $(zig version)"; echo "rust: $(rustc --version)"; echo "just: $(just --version)"; echo "font: ${SATIN_FONT:-unset}"; fi

# List Architecture Decision Records.
adr:
    @find docs/adr -maxdepth 1 -name '[0-9][0-9][0-9][0-9]-*.md' -print | sort

# Create a new Architecture Decision Record from docs/adr/template.md.
adr-new title:
    @title="{{title}}"; \
    slug=$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'); \
    last=$(find docs/adr -maxdepth 1 -name '[0-9][0-9][0-9][0-9]-*.md' -print | sed -E 's#.*/([0-9]{4})-.*#\1#' | sort -n | tail -1); \
    next=$(printf '%04d' $((10#${last:-0} + 1))); \
    path="docs/adr/${next}-${slug}.md"; \
    escaped_title=$(printf '%s' "$title" | sed -e 's/[\/&]/\\&/g'); \
    sed -e "s/NNNN/${next}/" -e "s/Title/${escaped_title}/" -e "s/YYYY-MM-DD/$(date +%F)/" docs/adr/template.md > "$path"; \
    echo "$path"

# Build and launch Satin detached without adding build/runtime output to this terminal.
terminal:
    @log="${TMPDIR:-/tmp}/satin-terminal.log"; \
    if [[ -z "${IN_NIX_SHELL:-}" ]]; then \
        if ! SATIN_LAUNCH_LOG="$log" nix develop --command just _terminal-detached >"$log" 2>&1; then cat "$log"; exit 1; fi; \
    else \
        if ! SATIN_LAUNCH_LOG="$log" just _terminal-detached >"$log" 2>&1; then cat "$log"; exit 1; fi; \
    fi

# Launch Satin in the foreground with build and runtime logs attached.
terminal-foreground:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then exec nix develop --command just terminal-foreground; else just native-dev-app && exec "spikes/macos-shell/.build/dev/Satin Dev.app/Contents/MacOS/satin-dev-app"; fi

[private]
_terminal-detached:
    @just native-dev-app
    @log="${SATIN_LAUNCH_LOG:-${TMPDIR:-/tmp}/satin-terminal.log}"; \
    app="$(pwd)/spikes/macos-shell/.build/dev/Satin Dev.app"; \
    environment=(PATH SATIN_FONT SATIN_LOG SATIN_NATIVE_PANE SATIN_UPDATE_SELF_TEST \
        SATIN_NATIVE_SMOKE_SCENARIO SATIN_NATIVE_SMOKE_RESULT SATIN_NATIVE_SMOKE_SHOT \
        SATIN_NATIVE_SMOKE_WINDOW_ID SATIN_NATIVE_SMOKE_KEEP_OPEN); \
    open_args=(); \
    for name in "${environment[@]}"; do if [[ -v "$name" ]]; then open_args+=(--env "$name=${!name}"); fi; done; \
    open -i /dev/null --stdout "$log" --stderr "$log" "${open_args[@]}" "$app"

# Launch the native Neovim UI pane.
neovim:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then exec nix develop --command just neovim; else just native-dev-app && SATIN_NATIVE_PANE=nvim exec "spikes/macos-shell/.build/dev/Satin Dev.app/Contents/MacOS/satin-dev-app"; fi

alias run := terminal
alias launch := terminal

# Build the native macOS terminal host.
native-build:
    @./scripts/native-build

# Build the isolated local development application bundle.
native-dev-app:
    @./scripts/native-dev-app

# Build and smoke the isolated Satin Dev application bundle.
native-dev-smoke:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then exec nix develop --command just native-dev-smoke; else just native-dev-app && SATIN_NATIVE_EXECUTABLE="spikes/macos-shell/.build/dev/Satin Dev.app/Contents/MacOS/satin-dev-app" ./scripts/native-smoke; fi

# Build and verify an optimized, hardened-runtime macOS application bundle.
native-package:
    @./scripts/native-package

# Sign, notarize, staple, and Gatekeeper-verify the macOS application bundle.
native-notarize:
    @./scripts/native-notarize

# Build a distributable archive and a checksummed update manifest.
native-release:
    @./scripts/native-release

# Build and verify the signed artifacts consumed by the tag release workflow.
native-signed-release:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then \
        exec nix develop --command just native-signed-release; \
    else \
        if [[ -z "${UPDATE_SIGNING_PRIVATE_KEY_B64:-}" ]]; then \
            echo "UPDATE_SIGNING_PRIVATE_KEY_B64 is required" >&2; \
            exit 64; \
        fi; \
        just native-release; \
        just native-update-release-smoke; \
    fi

# Build CI artifacts exactly once, then reuse the signed package downstream.
native-ci-build:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then \
        exec nix develop --command just native-ci-build; \
    else \
        just native-build; \
        SATIN_UPDATE_SELF_TEST=1 spikes/macos-shell/.build/SatinApplication; \
        just native-package; \
        ./scripts/native-update-install-smoke; \
        SATIN_USE_PREBUILT_PACKAGE=1 ./scripts/native-release; \
    fi

# Run the production smoke suite without recompiling unchanged native artifacts.
native-ci-smoke:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then \
        exec nix develop --command just native-ci-smoke; \
    else \
        test -x spikes/macos-shell/.build/SatinApplication; \
        test -d "spikes/macos-shell/.build/package/Satin.app"; \
        ./scripts/native-smoke; \
        ./scripts/native-settings-smoke; \
        ./scripts/native-control-smoke; \
        ./scripts/native-artifact-smoke; \
        ./scripts/native-kitty-smoke; \
        SATIN_USE_PREBUILT_PACKAGE=1 ./scripts/native-package-smoke; \
        SATIN_USE_PREBUILT_PACKAGE=1 ./scripts/native-finder-editor-smoke; \
        ./scripts/native-nvim-ui-surfaces-smoke; \
        ./scripts/native-resize-smoke; \
        ./scripts/native-session-smoke; \
        ./scripts/native-tab-bar-actions-smoke; \
        ./scripts/native-home-cwd-smoke; \
        ./scripts/native-terminal-exit-closes-tab-smoke; \
    fi

# Verify update metadata parsing and semantic-version ordering.
native-update-test:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then exec nix develop --command just native-update-test; else just native-build && SATIN_UPDATE_SELF_TEST=1 spikes/macos-shell/.build/SatinApplication; fi

# Verify the production update endpoint without consuming GitHub API quota.
native-update-live-smoke:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then exec nix develop --command just native-update-live-smoke; else version=$(sed -nE 's/^version = "([^"]+)"/\1/p' Cargo.toml | head -1); just native-build && SATIN_UPDATE_LIVE_CHECK_VERSION="$version" SATIN_UPDATE_LIVE_CHECK_EXPECTED=current spikes/macos-shell/.build/SatinApplication; fi

# Verify the external updater swaps, validates, and preserves the previous app.
native-update-install-smoke:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then exec nix develop --command just native-update-install-smoke; else just native-package && ./scripts/native-update-install-smoke; fi

# Verify a signed release with the public key embedded in the packaged app.
native-update-release-smoke:
    @./scripts/native-update-release-smoke

# Verify the native Settings window renders and its model self-tests pass.
native-settings-smoke:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then exec nix develop --command just native-settings-smoke; else just native-build && ./scripts/native-settings-smoke; fi

# Verify the owner-only control socket and every satin CLI command end to end.
native-control-smoke:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then exec nix develop --command just native-control-smoke; else just native-build && ./scripts/native-control-smoke; fi

# Verify versioning, rich Markdown, the recent popover, atomic splits, and Kitty images.
native-artifact-smoke:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then exec nix develop --command just native-artifact-smoke; else just native-build && ./scripts/native-artifact-smoke; fi

# Verify Kitty temp-file transfer, pane isolation, deletion, and Skia rendering.
native-kitty-smoke:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then exec nix develop --command just native-kitty-smoke; else just native-build && ./scripts/native-kitty-smoke; fi

# Build, launch briefly, capture the native shell view, and exit.
native-smoke:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then exec nix develop --command just native-smoke; else just native-build && ./scripts/native-smoke; fi

# Launch and visually verify the exact Release executable inside the application bundle.
native-package-smoke:
    @./scripts/native-package-smoke

# Verify Finder Open With launches one native editor pane through LaunchServices.
finder-editor-smoke:
    @./scripts/native-finder-editor-smoke

# Verify a shell nvim command uses native multigrid, scrolls with a terminal split, and resumes the same shell.
shell-nvim-smoke:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then exec nix develop --command just shell-nvim-smoke; else just native-build && ./scripts/native-shell-nvim-smoke; fi

# Verify bottom-line terminal input does not trigger synthetic scroll animation.
terminal-bottom-input-smoke:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then exec nix develop --command just terminal-bottom-input-smoke; else just native-build && ./scripts/native-terminal-bottom-input-smoke; fi

# Verify shell exit closes its terminal tab.
terminal-exit-closes-tab-smoke:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then exec nix develop --command just terminal-exit-closes-tab-smoke; else just native-build && ./scripts/native-terminal-exit-closes-tab-smoke; fi

# Verify versioned recursive pane session metadata round-trips.
native-session-smoke:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then exec nix develop --command just native-session-smoke; else just native-build && ./scripts/native-session-smoke; fi

# Verify tmux projection, history/modes/paste/zoom/CLI, reattach, detach, and recovery.
native-tmux-smoke:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then exec nix develop --command just native-tmux-smoke; else just native-build && ./scripts/native-tmux-smoke; fi

# Verify tab-bar buttons create a tab and both split axes through their click actions.
native-tab-bar-actions-smoke:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then exec nix develop --command just native-tab-bar-actions-smoke; else just native-build && ./scripts/native-tab-bar-actions-smoke; fi

# Verify an empty startup-directory setting resolves to the macOS user home.
native-home-cwd-smoke:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then exec nix develop --command just native-home-cwd-smoke; else just native-build && ./scripts/native-home-cwd-smoke; fi

# Verify native window changes resize terminal pane grids.
native-resize-smoke:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then exec nix develop --command just native-resize-smoke; else just native-build && ./scripts/native-resize-smoke; fi

# Repeat lifecycle, resize, session, input, and terminal/Neovim handoff smokes.
native-soak iterations="3":
    @./scripts/native-soak "{{iterations}}"

# Verify the explicit native Neovim command replaces a terminal pane.
terminal-nvim-handoff-smoke:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then exec nix develop --command just terminal-nvim-handoff-smoke; else just native-build && ./scripts/native-terminal-nvim-handoff-smoke; fi

# Verify explicitly opened native Neovim inherits the terminal pane working directory.
terminal-nvim-cwd-smoke:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then exec nix develop --command just terminal-nvim-cwd-smoke; else just native-build && ./scripts/native-terminal-nvim-cwd-smoke; fi

# Verify :qa from an explicitly opened native Neovim pane returns to terminal rendering.
terminal-nvim-quit-smoke:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then exec nix develop --command just terminal-nvim-quit-smoke; else just native-build && ./scripts/native-terminal-nvim-quit-smoke; fi

# Capture the native Neovim Skia/Metal pane and verify it is nonblank.
nvim-skia-smoke:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then exec nix develop --command just nvim-skia-smoke; else just native-build && ./scripts/native-nvim-smoke; fi

# Verify image.nvim-compatible Kitty graphics over native Neovim RPC and Skia/Metal.
nvim-image-smoke:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then exec nix develop --command just nvim-image-smoke; else just native-build && ./scripts/native-nvim-smoke nvim-image native-nvim-image-smoke nvim-image; fi

# Run all deterministic native Neovim animation smoke scenarios.
nvim-smoke-all:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then \
        exec nix develop --command just nvim-smoke-all; \
    else \
        just native-build; \
        just _nvim-smoke nvim-scroll; \
        just _nvim-smoke nvim-jump; \
        just _nvim-smoke nvim-side-pane; \
        just _nvim-smoke nvim-commandline; \
        just _nvim-smoke nvim-cursor-move; \
        just _nvim-smoke nvim-file-tree-cursor-move; \
        ./scripts/native-nvim-file-tree-close-smoke; \
        just _nvim-smoke nvim-shaped-text; \
        just _nvim-smoke-shaped-text-visual; \
        just _nvim-smoke-ui-surfaces; \
        just _nvim-smoke-popupmenu; \
        just _nvim-smoke-cursor-normal-shape; \
        just _nvim-smoke-cursor-shape; \
        just _nvim-smoke-cursor-replace-shape; \
        just _nvim-smoke-cursor-blink; \
        just _nvim-smoke-cursor-switch; \
    fi

# Verify Ctrl-D style Neovim scroll animation.
nvim-smoke-scroll:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then \
        exec nix develop --command just nvim-smoke-scroll; \
    else \
        just native-build && just _nvim-smoke nvim-scroll; \
    fi

# Verify large Neovim jump animation.
nvim-smoke-jump:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then \
        exec nix develop --command just nvim-smoke-jump; \
    else \
        just native-build && just _nvim-smoke nvim-jump; \
    fi

# Verify side-pane scroll hints stay column-bounded.
nvim-smoke-side-pane:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then \
        exec nix develop --command just nvim-smoke-side-pane; \
    else \
        just native-build && just _nvim-smoke nvim-side-pane; \
    fi

# Verify command-line input does not trigger scroll animation.
nvim-smoke-commandline:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then \
        exec nix develop --command just nvim-smoke-commandline; \
    else \
        just native-build && just _nvim-smoke nvim-commandline; \
    fi

# Verify cursor-only j/k movement in a one-screen buffer never animates the viewport.
nvim-smoke-cursor-move:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then \
        exec nix develop --command just nvim-smoke-cursor-move; \
    else \
        just native-build && just _nvim-smoke nvim-cursor-move; \
    fi

# Verify shaped Japanese, Nerd Font, combining, and ambiguous-width text reaches Skia.
nvim-smoke-shaped-text:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then \
        exec nix develop --command just nvim-smoke-shaped-text; \
    else \
        just native-build && just _nvim-smoke nvim-shaped-text; \
    fi

# Verify shaped text has visible glyph pixels in the captured Skia/Metal surface.
nvim-smoke-shaped-text-visual:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then \
        exec nix develop --command just nvim-smoke-shaped-text-visual; \
    else \
        just native-build && just _nvim-smoke-shaped-text-visual; \
    fi

_nvim-smoke-shaped-text-visual:
    @./scripts/native-nvim-shaped-text-visual-smoke

# Verify split, floating-window, message, and blend surfaces in model and screenshot.
nvim-smoke-ui-surfaces:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then \
        exec nix develop --command just nvim-smoke-ui-surfaces; \
    else \
        just native-build && just _nvim-smoke-ui-surfaces; \
    fi

_nvim-smoke-ui-surfaces:
    @./scripts/native-nvim-ui-surfaces-smoke

# Verify Neovim popupmenu reaches the retained model and Skia/Metal surface.
nvim-smoke-popupmenu:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then \
        exec nix develop --command just nvim-smoke-popupmenu; \
    else \
        just native-build && just _nvim-smoke-popupmenu; \
    fi

_nvim-smoke-popupmenu:
    @./scripts/native-nvim-popupmenu-smoke

# Verify file-tree plugin panes render and mouse selection can open a file.
nvim-smoke-file-tree:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then \
        exec nix develop --command just nvim-smoke-file-tree; \
    else \
        just native-build && just _nvim-smoke nvim-file-tree; \
    fi

# Verify one-row movement in the file tree does not animate any retained viewport.
nvim-smoke-file-tree-cursor-move:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then \
        exec nix develop --command just nvim-smoke-file-tree-cursor-move; \
    else \
        just native-build && just _nvim-smoke nvim-file-tree-cursor-move; \
    fi

# Verify closing the file tree removes its retained grid and separator column.
nvim-smoke-file-tree-close:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then \
        exec nix develop --command just nvim-smoke-file-tree-close; \
    else \
        just native-build && ./scripts/native-nvim-file-tree-close-smoke; \
    fi

# Verify Neovim mode cursor shape reaches the Skia/Metal cursor body.
nvim-smoke-cursor-shape:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then \
        exec nix develop --command just nvim-smoke-cursor-shape; \
    else \
        just native-build && just _nvim-smoke-cursor-shape; \
    fi

_nvim-smoke-cursor-shape:
    @./scripts/native-nvim-cursor-shape-smoke

# Verify normal mode block cursor shape reaches the Skia/Metal cursor body.
nvim-smoke-cursor-normal-shape:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then \
        exec nix develop --command just nvim-smoke-cursor-normal-shape; \
    else \
        just native-build && just _nvim-smoke-cursor-normal-shape; \
    fi

_nvim-smoke-cursor-normal-shape:
    @./scripts/native-nvim-cursor-shape-smoke nvim-cursor-normal-shape nvim-cursor-normal-shape cursor-normal-shape

# Verify replace mode horizontal cursor shape reaches the Skia/Metal cursor body.
nvim-smoke-cursor-replace-shape:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then \
        exec nix develop --command just nvim-smoke-cursor-replace-shape; \
    else \
        just native-build && just _nvim-smoke-cursor-replace-shape; \
    fi

_nvim-smoke-cursor-replace-shape:
    @./scripts/native-nvim-cursor-shape-smoke nvim-cursor-replace-shape nvim-cursor-replace-shape cursor-replace-shape

# Verify blink scheduling hides the Skia/Metal cursor body during the off phase.
nvim-smoke-cursor-blink:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then \
        exec nix develop --command just nvim-smoke-cursor-blink; \
    else \
        just native-build && just _nvim-smoke-cursor-blink; \
    fi

_nvim-smoke-cursor-blink:
    @./scripts/native-nvim-cursor-blink-smoke

# Verify cursor body is visible after tab switch and previous pane trail is gone.
nvim-smoke-cursor-switch:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then \
        exec nix develop --command just nvim-smoke-cursor-switch; \
    else \
        just native-build && just _nvim-smoke-cursor-switch; \
    fi

_nvim-smoke-cursor-switch:
    @./scripts/native-nvim-cursor-switch-smoke

_nvim-smoke scenario:
    @tmp=$(mktemp); \
    trap 'rm -f "$tmp"' EXIT; \
    clean_nvim=1; \
    if [[ "{{scenario}}" == nvim-file-tree* ]]; then clean_nvim=0; fi; \
    SATIN_NATIVE_PANE=nvim \
    SATIN_NATIVE_SMOKE_CLEAN_NVIM="$clean_nvim" \
    SATIN_NATIVE_SMOKE_SCENARIO="{{scenario}}" \
    SATIN_NATIVE_SMOKE_RESULT="$tmp" \
        spikes/macos-shell/.build/SatinApplication \
        >"/tmp/satin-{{scenario}}.log" 2>&1; \
    result=$(cat "$tmp"); \
    echo "$result"; \
    [[ "$result" == ok* ]]

# Check the Rust crate.
check:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then exec nix develop --command just check; else cargo check; fi

# Run tests.
test:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then exec nix develop --command just test; else cargo test; fi

# Run the zero-debt Rust lint gate.
lint:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then exec nix develop --command just lint; else cargo clippy --all-targets --all-features -- -D warnings; fi

# Run the checks enforced by the Git pre-commit hook.
precommit:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then exec nix develop --command just precommit; else just secrets-staged && cargo fmt -- --check && cargo clippy --all-targets --all-features -- -D warnings && cargo test && just license-audit && just ops-lint; fi

# Scan staged changes before a commit without printing detected values.
secrets-staged:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then exec nix develop --command just secrets-staged; else gitleaks git --pre-commit --staged --redact=100 --no-banner .; fi

# Scan every reachable Git ref and commit.
secrets-history:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then exec nix develop --command just secrets-history; else gitleaks git --log-opts=--all --redact=100 --no-banner .; fi

# Scan current tracked and untracked repository files, excluding generated outputs.
secrets-worktree:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then exec nix develop --command just secrets-worktree; else gitleaks dir --redact=100 --no-banner .; fi

# Run both publication-grade secret scans.
secrets:
    @just secrets-history
    @just secrets-worktree

# Lint release/smoke shell scripts and GitHub Actions workflows.
ops-lint:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then exec nix develop --command just ops-lint; else mapfile -t shell_scripts < <(rg -l '^#!.*(bash|/sh)' scripts --glob '*' | sort); shellcheck "${shell_scripts[@]}" && zsh -n scripts/shell-integration/zsh/.zshenv scripts/shell-integration/zsh/.zprofile scripts/shell-integration/zsh/.zshrc scripts/shell-integration/zsh/.zlogin scripts/shell-integration/zsh/.zlogout && actionlint .github/workflows/*.yml; fi

# Configure this clone to use the repository-managed Git hooks.
install-hooks:
    @git config core.hooksPath .githooks
    @chmod +x .githooks/pre-commit
    @echo "Git hooks installed from .githooks"

# Format Rust sources.
fmt:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then exec nix develop --command just fmt; else cargo fmt; fi

# Verify formatting, type checking, linting, and tests.
verify:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then exec nix develop --command just verify; else cargo fmt -- --check && cargo check && cargo clippy --all-targets --all-features -- -D warnings && cargo test && just license-audit && just ops-lint; fi

# Verify third-party attribution, exact bundled font provenance, and Cargo licenses.
license-audit:
    @./scripts/license-audit

# Remove Rust build artifacts.
clean:
    @if [[ -z "${IN_NIX_SHELL:-}" ]]; then exec nix develop --command just clean; else cargo clean; fi
