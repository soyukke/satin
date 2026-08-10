# Native Neovim diff benchmark

Run the isolated two-window workload:

```sh
just nvim-perf current synthetic
```

Run Diffview with the current user configuration:

```sh
just nvim-perf current user
```

Both workloads use a 15-point font and record eight seconds by default. The
full JSON report is written below
`spikes/macos-shell/.build/nvim-performance/<label>/summary.json`; generated
reports are ignored by Git. Set `SATIN_PERF_DURATION_SECONDS` to change the
sample window or `SATIN_PERF_DIFFVIEW_RANGE` to change the user-workload range.

The report separates renderer and frame-submission CPU, presentation cadence,
GPU queue latency, main-thread drain time, Satin and Neovim process CPU, peak
combined RSS, Neovim operation cadence, and grid geometry. Compare runs only
when `nvim.columns` and `nvim.lines` match.
