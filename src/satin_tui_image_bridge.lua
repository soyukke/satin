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

  local function chunks(value)
    local result = {}
    for index = 1, #value, 4096 do
      local chunk = value:sub(index, index + 4095):gsub("%s", "")
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

  local function write_graphics(config, path)
    local effective = vim.deepcopy(config)
    if type(effective.display_zindex) == "number" and effective.display_zindex < 0 then
      effective.display_zindex = 0
    end
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
      write("\27_G" .. payload .. "\27\\", effective.tty, true)
      return
    end

    local encoded = vim.base64.encode(data):gsub("%-", "/")
    local parts = chunks(encoded)
    for index, part in ipairs(parts) do
      local more = index < #parts and 1 or 0
      local prefix = index == 1 and (payload .. ",m=" .. more) or ("m=" .. more)
      write("\27_G" .. prefix .. ";" .. part .. "\27\\", effective.tty, true)
      if index < #parts then
        uv.sleep(1)
      end
    end
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
    write_placeholder = write_placeholder,
    update_sync_start = function()
      write("\27[?2026h")
    end,
    update_sync_end = function()
      write("\27[?2026l")
    end,
  }
end

local satin_features = type(vim.g.satin_features) == "table" and vim.g.satin_features or {}
satin_features.kitty_graphics = true
vim.g.satin_features = satin_features
