local satin_features = type(vim.g.satin_features) == "table" and vim.g.satin_features or {}

if vim.env.TMUX then
  -- A tmux server child does not necessarily have a controlling /dev/tty on
  -- macOS. satin-nvim only installs this bridge when stdout itself is a TTY.
  local scroll_output = io.stdout
  if scroll_output then
    local function write_scroll_event(rows, top, bottom, left, right)
      local payload = string.format(
        "\27]777;SatinScroll;1;%d;%d;%d;%d;%d\7",
        rows,
        top,
        bottom,
        left,
        right
      )
      if vim.env.SATIN_SMOKE_SPLIT_SCROLL_OSC == "1" then
        local split_at = math.floor(#payload / 2)
        scroll_output:write(payload:sub(1, split_at))
        scroll_output:flush()
        vim.uv.sleep(10)
        scroll_output:write(payload:sub(split_at + 1))
        scroll_output:flush()
        return
      end
      scroll_output:write(payload)
      scroll_output:flush()
    end

    local group = vim.api.nvim_create_augroup("SatinTuiScroll", { clear = true })
    vim.api.nvim_create_autocmd("WinScrolled", {
      group = group,
      callback = function()
        for key, change in pairs(vim.v.event) do
          local window = tonumber(key)
          local rows = type(change) == "table" and tonumber(change.topline) or nil
          local resized =
            type(change) ~= "table"
            or tonumber(change.width) ~= 0
            or tonumber(change.height) ~= 0
          if window and rows and rows ~= 0 and not resized and vim.api.nvim_win_is_valid(window) then
            local position = vim.fn.win_screenpos(window)
            local top = tonumber(position[1]) or 0
            local left = tonumber(position[2]) or 0
            local bottom = top + vim.api.nvim_win_get_height(window) - 1
            local right = left + vim.api.nvim_win_get_width(window) - 1
            local rectangular = left > 1 or right < vim.o.columns
            if rectangular and top > 0 and bottom >= top and right >= left then
              write_scroll_event(rows, top, bottom, left, right)
            end
          end
        end
      end,
    })
    satin_features.scroll_events = true
  end
end

package.preload["image/backends/kitty/helpers"] = function()
  local codes = require("image/backends/kitty/codes")
  local utils = require("image/utils")
  local uv = vim.uv or vim.loop
  local editor_tty = utils.term.get_tty()
  if not editor_tty then
    error("Satin image bridge could not resolve the editor tty")
  end
  local editor_output, open_error = io.open(editor_tty, "w")
  if not editor_output then
    error("Satin image bridge failed to open editor tty: " .. tostring(open_error))
  end

  local function write(data, tty, escape)
    if data == "" then
      return
    end
    if escape and utils.tmux.is_tmux then
      data = utils.tmux.escape(data)
    end
    if not tty or tty == editor_tty then
      -- Keep one DCS indivisible from Neovim's own TUI redraws. A libuv stdout
      -- write can be split and interleaved while a large Kitty chunk is queued.
      editor_output:write(data)
      editor_output:flush()
      return
    end
    local handle, target_error = io.open(tty, "w")
    if not handle then
      error("Satin image bridge failed to open tty: " .. tostring(target_error))
    end
    handle:write(data)
    handle:flush()
    handle:close()
  end

  local function chunks(value, requested_size)
    local chunk_size =
      type(requested_size) == "number" and requested_size > 0 and requested_size or 4096
    local result = {}
    for index = 1, #value, chunk_size do
      local chunk = value:sub(index, index + chunk_size - 1):gsub("%s", "")
      if #chunk > 0 then
        table.insert(result, chunk)
      end
    end
    return result
  end

  local function control_payload(config)
    local fields = {}
    for name, value in pairs(config) do
      local key = codes.control.keys[name]
      if key and value ~= nil then
        if type(value) == "number" then
          value = string.format("%d", value)
        end
        table.insert(fields, key .. "=" .. value)
      end
    end
    table.sort(fields)
    return table.concat(fields, ",")
  end

  local function graphics_config(config)
    local effective = vim.deepcopy(config)
    if type(effective.display_zindex) == "number" and effective.display_zindex < 0 then
      effective.display_zindex = 0
    end
    return effective
  end

  local function graphics_sequence(config)
    return "\27_G" .. control_payload(config) .. "\27\\"
  end

  local function write_graphics(config, path, direct_chunk_size)
    local effective = graphics_config(config)
    local data = nil
    if path then
      -- The producer reads its own file and sends direct bytes. Satin therefore
      -- never needs to enable arbitrary Kitty file reads in the terminal host.
      local file, open_error = io.open(path, "rb")
      if not file then
        error("Satin image bridge could not read image: " .. tostring(open_error))
      end
      data = file:read("*all")
      file:close()
      effective.transmit_medium = codes.control.transmit_medium.direct
    end

    local payload = control_payload(effective)
    if not data then
      write(graphics_sequence(effective), effective.tty, true)
      return
    end

    local encoded = vim.base64.encode(data):gsub("%-", "/")
    local parts = chunks(encoded, direct_chunk_size)
    for index, part in ipairs(parts) do
      local more = index < #parts and 1 or 0
      local prefix = index == 1 and (payload .. ",m=" .. more) or ("m=" .. more)
      write("\27_G" .. prefix .. ";" .. part .. "\27\\", effective.tty, true)
      if index < #parts then
        uv.sleep(1)
      end
    end
  end

  local function write_graphics_at(config, x, y)
    if utils.tmux.is_tmux then
      local pane_position = utils.tmux.get_pane_position()
      x = x + pane_position.left
      y = y + pane_position.top
    end
    local sequence = "\27[?2026h\27[s\27["
      .. y
      .. ";"
      .. x
      .. "H"
      .. graphics_sequence(graphics_config(config))
      .. "\27[u\27[?2026l"
    write(sequence, nil, true)
  end

  local function move_cursor(x, y, save)
    if save then
      write("\27[s")
    end
    write("\27[" .. y .. ";" .. x .. "H")
    uv.sleep(1)
  end

  local function write_placeholder(image_id, x, y, width, height)
    write("\27[38;5;" .. image_id .. "m")
    for row = 0, height - 1 do
      move_cursor(x, y + row + 1, false)
      for column = 0, width - 1 do
        write(codes.placeholder .. codes.diacritics[row + 1] .. codes.diacritics[column + 1])
      end
    end
    write("\27[39m")
  end

  return {
    move_cursor = move_cursor,
    restore_cursor = function()
      write("\27[u")
    end,
    write = write,
    write_graphics = write_graphics,
    write_graphics_at = write_graphics_at,
    write_placeholder = write_placeholder,
    update_sync_start = function()
      write("\27[?2026h")
    end,
    update_sync_end = function()
      write("\27[?2026l")
    end,
  }
end

satin_features.kitty_graphics = true
vim.g.satin_features = satin_features
