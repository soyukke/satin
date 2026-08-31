local function rpc_channel()
  for _, channel in ipairs(vim.api.nvim_list_chans()) do
    if channel.mode == "rpc" and channel.stream == "stdio" then
      return channel.id
    end
  end
  return 1
end

local channel = rpc_channel()

local function notify_cwd()
  local cwd = vim.fn.getcwd()
  if type(cwd) ~= "string" or cwd == "" then
    return
  end
  local ok, failure = pcall(vim.rpcnotify, channel, "satin_cwd_changed", cwd)
  if not ok then
    error("Satin working-directory bridge failed: " .. tostring(failure))
  end
end

-- The host already seeds the initial cwd. An eager startup notification can
-- race the first embedded file redraw, so only real DirChanged events notify.
local group = vim.api.nvim_create_augroup("SatinWorkingDirectory", { clear = true })
vim.api.nvim_create_autocmd("DirChanged", {
  group = group,
  callback = notify_cwd,
})
