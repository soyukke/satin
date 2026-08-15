# README demo media

The README embeds three short GIF previews and links each one to an H.264 MP4:

- `assets/satin-demo.*` shows terminal cursor input, a native pane split, and
  native Neovim cursor and Ctrl-D/Ctrl-U scroll animation.
- `assets/satin-work-switcher-demo.*` shows projected tmux panes reporting live
  agent status in the experimental Work Switcher.
- `assets/satin-artifact-demo.*` shows a versioned Markdown artifact opening and
  refreshing in the window-scoped sidebar.

The tracked poster PNGs are review aids and should be refreshed with the videos
even though the README currently embeds the GIFs.

## Record

Run the recording recipe from Apple Terminal or another terminal outside Satin:

```sh
SATIN_ALLOW_SCREEN_CAPTURE=1 just readme-demo
```

The recipe deliberately refuses to run inside a Satin pane. It builds an
isolated `Satin Dev.app`, creates temporary tmux and artifact stores, and records
only that app's windows through ScreenCaptureKit at the display's native frame
rate without audio. Other applications remain excluded even if they move in
front during recording. The Work Switcher scene extends its black capture canvas
to keep the real toolbar-anchored popover visible. The recipe replaces all nine
tracked demo assets only after all three captures decode successfully and does
not open macOS's interactive screenshot/recording mode. The terminal and Git
fixtures are generated under a private temporary directory; they contain no
working repository content, prompts, credentials, or user home paths.

macOS may ask the external terminal for Screen & System Audio Recording access.
Grant it only when this explicit recording is intended. Do not run
`native-window-capture`, `native-visual-smoke`, or this recipe while self-hosting
inside Satin.

## Review

Review all three MP4s in QuickTime and inspect their GIF and poster frames.
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
