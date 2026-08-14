local bridge = {}

local function rpc_channel()
  for _, channel in ipairs(vim.api.nvim_list_chans()) do
    if channel.mode == "rpc" and channel.stream == "stdio" then
      return channel.id
    end
  end
  return 1
end

function bridge.write(data)
  if data == "" then
    return
  end
  local ok, failure = pcall(vim.rpcnotify, rpc_channel(), "satin_kitty_graphics", data)
  if not ok then
    error("Satin Kitty graphics bridge failed: " .. tostring(failure))
  end
end

function bridge.size()
  local columns = math.max(tonumber(vim.o.columns) or 1, 1)
  local rows = math.max(tonumber(vim.o.lines) or 1, 1)
  local pixel_width = math.max(tonumber(vim.g.satin_pixel_width) or columns, columns)
  local pixel_height = math.max(tonumber(vim.g.satin_pixel_height) or rows, rows)
  return {
    screen_x = pixel_width,
    screen_y = pixel_height,
    screen_cols = columns,
    screen_rows = rows,
    cell_width = pixel_width / columns,
    cell_height = pixel_height / rows,
  }
end

package.preload["satin.image"] = function()
  return bridge
end

-- image.nvim reads terminal geometry during module initialization. Native
-- Neovim has no TTY because stdout carries MessagePack RPC, so expose geometry
-- supplied by the host instead.
package.preload["image/utils/term"] = function()
  return {
    get_size = bridge.size,
    get_tty = function()
      return nil
    end,
  }
end

-- Keep image.nvim's Kitty backend and replace only its transport. This lets
-- image.nvim retain ownership of layout, cropping, and deletion while Satin
-- reuses the same libghostty-vt decoder as terminal panes.
package.preload["image/backends/kitty/helpers"] = function()
  local codes = require("image/backends/kitty/codes")
  local uv = vim.uv or vim.loop

  local function chunks(value, requested_size)
    -- Leave room for the Kitty control sequence inside the host's 64 KiB RPC
    -- notification bound.
    local chunk_size = 4096
    if type(requested_size) == "number" and requested_size > 0 then
      chunk_size = math.min(requested_size, 60 * 1024)
    end
    local result = {}
    for index = 1, #value, chunk_size do
      local chunk = value:sub(index, index + chunk_size - 1):gsub("%s", "")
      if #chunk > 0 then
        table.insert(result, chunk)
      end
    end
    return result
  end

  local function write(data)
    bridge.write(data)
  end

  local function move_cursor(x, y, save)
    if save then
      write("\27[s")
    end
    write("\27[" .. y .. ";" .. x .. "H")
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
      -- Native multigrid windows are composited before protocol overlays. An
      -- image.nvim placement already owns blank editor cells, so keep it above
      -- the retained window surface while text/pop-up masking remains managed
      -- by image.nvim.
      effective.display_zindex = 0
    end
    return effective
  end

  local function graphics_sequence(config)
    return "\27_G" .. control_payload(config) .. "\27\\"
  end

  local function write_graphics(config, data, direct_chunk_size)
    local effective = graphics_config(config)
    if data then
      local file, open_error = io.open(data, "rb")
      if not file then
        error("Satin image bridge could not read image: " .. tostring(open_error))
      end
      data = file:read("*all")
      file:close()
      effective.transmit_medium = codes.control.transmit_medium.direct
    end

    local payload = control_payload(effective)
    if not data then
      write(graphics_sequence(effective))
      return
    end

    local encoded = vim.base64.encode(data):gsub("%-", "/")
    local parts = chunks(encoded, direct_chunk_size)
    for index, part in ipairs(parts) do
      local more = index < #parts and 1 or 0
      local prefix = index == 1 and (payload .. ",m=" .. more) or ("m=" .. more)
      write("\27_G" .. prefix .. ";" .. part .. "\27\\")
      if index < #parts then
        uv.sleep(1)
      end
    end
  end

  local function write_graphics_at(config, x, y)
    local sequence = "\27[?2026h\27[s\27["
      .. y
      .. ";"
      .. x
      .. "H"
      .. graphics_sequence(graphics_config(config))
      .. "\27[u\27[?2026l"
    write(sequence)
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

local satin_features = type(vim.g.satin_features) == "table" and vim.g.satin_features or {}
satin_features.kitty_graphics = true
vim.g.satin_features = satin_features
