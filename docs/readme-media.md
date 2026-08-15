# README demo media

The README embeds two short GIF previews and links each one to an H.264 MP4:

- `assets/satin-demo.*` shows native tmux projection and the Work Switcher.
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
isolated `Satin Dev.app`, creates temporary tmux and artifact stores, records
only that app's window as a five-frame-per-second image sequence without audio,
and replaces all six tracked demo assets only after both captures decode
successfully. It does not open macOS's interactive screenshot/recording mode.
The fixtures contain no working repository content, prompts, credentials, or
user home paths.

macOS may ask the external terminal for Screen & System Audio Recording access.
Grant it only when this explicit recording is intended. Do not run
`native-window-capture`, `native-visual-smoke`, or this recipe while self-hosting
inside Satin.

## Review

Review both MP4s in QuickTime and inspect their GIF and poster frames. Confirm
that text is readable, no unrelated windows or notifications appear, and the
README captions match the recorded duration and behavior. Then run:

```sh
just precommit
```

The recipe fixes MP4 output at 1100×720 and GIF output at 880×576, strips audio,
uses `yuv420p` for browser compatibility, and verifies both animated formats by
decoding them before replacing the repository assets.
