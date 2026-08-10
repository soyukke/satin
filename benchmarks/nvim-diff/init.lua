local uv = vim.uv or vim.loop

local ready_path = assert(os.getenv("SATIN_BENCH_READY"))
local start_path = assert(os.getenv("SATIN_PERF_START"))
local result_path = assert(os.getenv("SATIN_BENCH_RESULT"))
local duration_ns = tonumber(os.getenv("SATIN_BENCH_DURATION_NS")) or 8e9

local function write_file(path, contents)
  local file = assert(io.open(path, "w"))
  file:write(contents)
  file:close()
end

local function configure_diff_workload()
  vim.opt.termguicolors = true
  vim.opt.lazyredraw = false
  vim.opt.updatetime = 10000
  vim.opt.diffopt:append({ "internal", "algorithm:histogram", "linematch:60" })
  vim.cmd("syntax enable")

  local left_lines = {}
  local right_lines = {}
  for index = 1, 4000 do
    local common = string.format(
      "pub fn item_%04d(value: i64) -> i64 { let base = value * %d; base + %d } // context",
      index,
      index % 19 + 1,
      index % 31
    )
    left_lines[index] = index % 3 == 0 and common:gsub("base %+", "base -") or common
    right_lines[index] = index % 4 == 0
        and common:gsub("context", "changed diff highlight")
      or common
  end

  local left_buffer = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(left_buffer, "before.rs")
  vim.api.nvim_buf_set_lines(left_buffer, 0, -1, false, left_lines)
  vim.bo[left_buffer].filetype = "rust"
  vim.bo[left_buffer].swapfile = false

  local left_window = vim.api.nvim_get_current_win()
  vim.cmd("vnew")
  local right_window = vim.api.nvim_get_current_win()
  local right_buffer = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(right_buffer, "after.rs")
  vim.api.nvim_buf_set_lines(right_buffer, 0, -1, false, right_lines)
  vim.bo[right_buffer].filetype = "rust"
  vim.bo[right_buffer].swapfile = false

  for _, window in ipairs({ left_window, right_window }) do
    vim.api.nvim_win_call(window, function()
      vim.wo.wrap = false
      vim.wo.number = true
      vim.wo.relativenumber = false
      vim.wo.cursorline = true
      vim.wo.scrollbind = true
      vim.wo.foldenable = false
      vim.cmd("diffthis")
      vim.cmd("normal! gg")
    end)
  end
  vim.api.nvim_set_current_win(left_window)
  vim.cmd("syncbind")
  vim.cmd("redraw!")
  return left_window
end

local function run_benchmark()
  local left_window = configure_diff_workload()
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
    local mean_interval_ms = operations > 1
        and interval_sum_ns / (operations - 1) / 1e6
      or 0
    write_file(result_path, vim.json.encode({
      operations = operations,
      elapsed_ms = elapsed_ns / 1e6,
      operations_per_second = operations * 1e9 / elapsed_ns,
      mean_interval_ms = mean_interval_ms,
      max_interval_ms = interval_max_ns / 1e6,
      intervals_over_16ms = over_16ms,
      intervals_over_33ms = over_33ms,
      final_topline = vim.fn.line("w0", left_window),
      columns = vim.o.columns,
      lines = vim.o.lines,
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
    vim.schedule(run_benchmark)
  end,
})
