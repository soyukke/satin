local uv = vim.uv or vim.loop

local ready_path = assert(os.getenv("SATIN_BENCH_READY"))
local start_path = assert(os.getenv("SATIN_PERF_START"))
local result_path = assert(os.getenv("SATIN_BENCH_RESULT"))
local duration_ns = tonumber(os.getenv("SATIN_BENCH_DURATION_NS")) or 8e9
local revision_range = os.getenv("SATIN_PERF_DIFFVIEW_RANGE") or "HEAD~2..HEAD~1"

local function write_file(path, contents)
  local file = assert(io.open(path, "w"))
  file:write(contents)
  file:close()
end

local function fail(message)
  write_file(ready_path .. ".error", message .. "\n")
end

local function find_diff_window()
  for _, window in ipairs(vim.api.nvim_list_wins()) do
    if vim.wo[window].diff then
      return window
    end
  end
  return nil
end

local function start_scroll_loop(diff_window)
  vim.api.nvim_set_current_win(diff_window)
  vim.cmd("normal! gg")
  vim.cmd("redraw!")
  write_file(ready_path, "ready\n")

  local timer = assert(uv.new_timer())
  local pending = false
  local started_at = nil
  local previous_at = nil
  local operations = 0
  local interval_sum_ns = 0
  local interval_max_ns = 0
  local over_16ms = 0
  local over_33ms = 0

  local function finish(now)
    timer:stop()
    timer:close()
    local elapsed_ns = now - started_at
    write_file(result_path, vim.json.encode({
      operations = operations,
      elapsed_ms = elapsed_ns / 1e6,
      operations_per_second = operations * 1e9 / elapsed_ns,
      mean_interval_ms = operations > 1
          and interval_sum_ns / (operations - 1) / 1e6
        or 0,
      max_interval_ms = interval_max_ns / 1e6,
      intervals_over_16ms = over_16ms,
      intervals_over_33ms = over_33ms,
      final_topline = vim.fn.line("w0", diff_window),
      columns = vim.o.columns,
      lines = vim.o.lines,
      visible_windows = #vim.api.nvim_list_wins(),
      workload = "user-diffview",
    }) .. "\n")
  end

  local function tick()
    pending = false
    if not started_at then
      if uv.fs_stat(start_path) then
        started_at = uv.hrtime()
        previous_at = started_at
      end
      return
    end

    local now = uv.hrtime()
    if now - started_at >= duration_ns then
      finish(now)
      return
    end
    if operations > 0 then
      local interval_ns = now - previous_at
      interval_sum_ns = interval_sum_ns + interval_ns
      interval_max_ns = math.max(interval_max_ns, interval_ns)
      if interval_ns > 16e6 then
        over_16ms = over_16ms + 1
      end
      if interval_ns > 33e6 then
        over_33ms = over_33ms + 1
      end
    end
    previous_at = now
    operations = operations + 1
    local key = math.floor((operations - 1) / 64) % 2 == 0 and "\005" or "\025"
    vim.api.nvim_feedkeys(key, "nx", false)
  end

  timer:start(0, 8, function()
    if pending then
      return
    end
    pending = true
    vim.schedule(tick)
  end)
end

vim.api.nvim_create_autocmd("UIEnter", {
  once = true,
  callback = function()
    vim.defer_fn(function()
      local benchmark_cwd = os.getenv("SATIN_PERF_CWD")
      if benchmark_cwd and benchmark_cwd ~= "" then
        vim.cmd.cd(vim.fn.fnameescape(benchmark_cwd))
      end
      local lazy_ok, lazy = pcall(require, "lazy")
      if lazy_ok then
        lazy.load({ plugins = { "diffview.nvim" } })
      end
      local ok, error_message = pcall(vim.cmd, "DiffviewOpen " .. revision_range)
      if not ok then
        fail("DiffviewOpen failed: " .. tostring(error_message))
        return
      end
      vim.defer_fn(function()
        local diff_window = find_diff_window()
        if not diff_window then
          fail("Diffview did not create a visible diff window")
          return
        end
        start_scroll_loop(diff_window)
      end, 2000)
    end, 2000)
  end,
})
