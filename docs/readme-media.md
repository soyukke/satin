# README demo media

The README embeds four short GIF previews and links each one to an H.264 MP4:

- `assets/satin-demo.*` shows terminal cursor input, a native pane split, and
  native Neovim cursor and Ctrl-D/Ctrl-U scroll animation.
- `assets/satin-artifact-demo.*` shows a versioned Markdown page opening and
  refreshing in the window-scoped sidebar.
- `assets/satin-attention-hand-demo.*` shows four agents asking for attention,
  their cards being dealt, Command-J choosing a card, and each played card
  switching to its pane.
- `assets/satin-sidebars-demo.*` shows four agent tabs as cards in the windows
  sidebar and the items sidebar gathering one agent's commands, quotes, links
  and files; an Option-click pastes a command, a click opens a Markdown file in
  the sidebar, Command-J plays the foil card, and the windows sidebar folds to
  its rail in the terminal and paper looks.

The tracked poster PNGs are review aids and should be refreshed with the videos
even though the README currently embeds the GIFs.

## Record

Run the recording recipe from Apple Terminal or another terminal outside Satin:

```sh
SATIN_ALLOW_SCREEN_CAPTURE=1 just readme-demo
```

Without a signing identity the recipe refuses to run inside a Satin pane: macOS
charges a bare recording tool to the terminal that ran it, and an ad-hoc signed
Satin is a new application to macOS after every rebuild, so the grant would be
asked for again each time. To record from inside Satin, or to be asked only
once, name a code-signing identity from your keychain:

```sh
SATIN_ALLOW_SCREEN_CAPTURE=1 \
  SATIN_RECORDER_SIGNING_IDENTITY="Apple Development: …" \
  just readme-demo
```

The recorder then runs as its own `Satin Recorder` application with that
signature. Allow it once under System Settings → Privacy & Security → Screen &
System Audio Recording; the grant survives rebuilds. The identity stays on your
machine and is not recorded anywhere in the repository.

The recipe builds an isolated `Satin Dev.app`, creates temporary page
stores, and records
only that app's windows through ScreenCaptureKit at the display's native frame
rate without audio. Other applications remain excluded even if they move in
front during recording. The attention hand and
sidebars scenes turn the hand on for their own windows only. The sidebars
scene opens the sidebars and the other scenes fold both to their rails,
whatever your Satin Dev preferences say. The recipe replaces the chosen scenes'
MP4, GIF, and poster only after every capture decodes successfully and does
not open macOS's interactive screenshot/recording mode. The terminal and Git
fixtures are generated under a private temporary directory; they contain no
working repository content, prompts, credentials, or user home paths.

macOS may ask the external terminal, or Satin Recorder, for Screen & System
Audio Recording access. Grant it only when this explicit recording is intended.
Do not run `native-window-capture` or `native-visual-smoke` while self-hosting
inside Satin; they still capture as the terminal that runs them.

To record only some scenes, name them; the other assets stay as they are:

```sh
SATIN_ALLOW_SCREEN_CAPTURE=1 SATIN_README_DEMO_SCENES=sidebars just readme-demo
```

The scenes are `main`, `artifact`, `hand`, and `sidebars`. The
sidebars scene copies a command and a link, so it replaces the clipboard.

## Rehearse

A dry run plays the same scenes without recording, so it needs no Screen &
System Audio Recording access and may run inside Satin. Every two seconds it
draws the window into a PNG in the directory you name:

```sh
SATIN_README_DEMO_DRY_RUN=/tmp/satin-demo-stills SATIN_README_DEMO_SCENES=sidebars \
  just readme-demo
```

The stills come from AppKit, so they show the sidebars, cards, and hands but
not the text the panes draw through Metal.

## Review

Review each recorded MP4 in QuickTime and inspect their GIF and poster frames.
Confirm that terminal and Neovim motion is visible, the Work Switcher remains
inside the Satin window, text is readable, no unrelated windows or notifications
appear, and the README captions match the recorded duration and behavior. Then
run:

```sh
just precommit
```

The recipe fixes MP4 output at 1100×720 and 30 frames per second, GIF output at
880×576 and 15 frames per second, strips audio, uses `yuv420p` for browser
compatibility, and verifies both animated formats by decoding them before
replacing the repository assets.
