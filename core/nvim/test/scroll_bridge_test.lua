-- Runs the scroll half of the tmux bridge in a real Neovim. The windows are
-- laid out and the bridge's functions called directly, so nothing here waits
-- on a screen, a terminal, or the time.
dofile(assert(arg[1], "the bridge's path"))
local scroll = assert(package.loaded["satin.scroll"], "the bridge did not load its scroll events")

local failures = 0

local function check(name, expected, actual)
  if expected ~= actual then
    failures = failures + 1
    io.stderr:write(string.format("FAIL %s\n  expected %s\n  actual   %s\n", name, vim.inspect(expected), vim.inspect(actual)))
  end
end

local function osc(rows, top, bottom, left, right)
  return string.format("\27]777;SatinScroll;2;%d;%d;%d;%d;%d\7", rows, top, bottom, left, right)
end

local function moved(topline, skipcol)
  return { topline = topline, skipcol = skipcol or 0, leftcol = 0, width = 0, height = 0 }
end

-- One window on a new buffer of count lines, each width columns wide.
local function fresh(count, width)
  vim.cmd("silent! only!")
  vim.cmd("enew!")
  vim.wo.winbar = ""
  vim.wo.wrap = true
  vim.wo.number = false
  local lines = {}
  for index = 1, count do
    lines[index] = string.rep("x", width or 10)
  end
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  -- A buffer that just came into the window names no scroll until the event
  -- loop has turned.
  vim.wait(0)
  return vim.api.nvim_get_current_win()
end

local function top_at(line)
  vim.fn.winrestview({ topline = line, lnum = line })
end

-- A headless Neovim keeps the 80 columns it starts with.
vim.o.columns = 80
vim.o.lines = 40
vim.o.laststatus = 2
vim.o.cmdheight = 1
vim.o.showtabline = 0
vim.o.hidden = true

do
  local window = fresh(200)
  top_at(31)
  check("a full-width window names its scroll", osc(30, 1, 38, 1, 80), scroll.payload(window, moved(30)))
  top_at(11)
  check("text moving down is negative", osc(-20, 1, 38, 1, 80), scroll.payload(window, moved(-20)))
end

do
  local window = fresh(30, 250)
  top_at(6)
  check("a wrapped line counts the rows it takes", osc(20, 1, 38, 1, 80), scroll.payload(window, moved(5)))
end

do
  local window = fresh(100)
  vim.wo.foldmethod = "manual"
  vim.cmd("10,29fold")
  top_at(31)
  check("a closed fold counts one row", osc(11, 1, 38, 1, 80), scroll.payload(window, moved(30)))
  vim.cmd("normal! zE")
end

do
  local window = fresh(200, 300)
  vim.wo.smoothscroll = true
  check("smooth scrolling counts whole rows", osc(3, 1, 38, 1, 80), scroll.payload(window, moved(0, 240)))
  check("and upward", osc(-3, 1, 38, 1, 80), scroll.payload(window, moved(0, -240)))
  vim.wo.smoothscroll = false
end

do
  local window = fresh(200)
  vim.cmd("topleft 30vnew")
  vim.cmd("wincmd l")
  top_at(4)
  check("a window beside a tree names only its columns", osc(3, 1, 38, 32, 80), scroll.payload(window, moved(3)))
end

do
  local window = fresh(200)
  vim.cmd("belowright split")
  vim.cmd("wincmd k")
  top_at(4)
  local bottom = vim.fn.winheight(window)
  check("a window above a split names only its rows", osc(3, 1, bottom, 1, 80), scroll.payload(window, moved(3)))
end

do
  local window = fresh(200)
  vim.wo.winbar = "title"
  top_at(4)
  check("a winbar stays out of the region", osc(3, 2, 38, 1, 80), scroll.payload(window, moved(3)))
end

do
  local window = fresh(200)
  check("no movement names nothing", nil, scroll.payload(window, moved(0)))
  check("a resize names nothing", nil, scroll.payload(window, { topline = 3, skipcol = 0, width = 1, height = 0 }))
  check("a closed window names nothing", nil, scroll.payload(99999, moved(3)))
end

do
  local other = fresh(200)
  vim.cmd("rightbelow vsplit")
  local current = vim.api.nvim_get_current_win()
  top_at(4)
  vim.api.nvim_win_call(other, function()
    top_at(4)
  end)
  local event = { all = moved(3), [tostring(other)] = moved(3), [tostring(current)] = moved(3) }
  local payloads = scroll.payloads(event)
  check("every window that moved is named", 2, #payloads)
  check("the current window is named last", scroll.payload(current, moved(3)), payloads[2])
end

do
  local window = fresh(200)
  top_at(50)
  vim.cmd("enew")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.fn["repeat"]({ "text" }, 200))
  top_at(4)
  local event = { [tostring(window)] = moved(3) }
  check("another buffer in the window is no scroll", 0, #scroll.payloads(event))
  vim.wait(0)
  check("the window's next scroll is one", 1, #scroll.payloads(event))
end

if failures > 0 then
  io.stderr:write(failures .. " failed\n")
  os.exit(1)
end
print("scroll bridge: ok")
os.exit(0)
