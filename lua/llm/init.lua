local M = {}

-- options
function M.setup(opts)
  local config = require "llm.config"
  config.setup(opts)
  local api = require "llm.api"
  local servers = require "llm.servers"
  local notify = require "llm.notify"
  -- ensure default server is selected
  servers.set_server_selected(config.options.default_server)

  vim.api.nvim_create_user_command("LLM", function(options)
    local args = options.fargs
    local command = args[1]
    if command == nil then
      api.start_chat()
    elseif command == "Chat" then
      api.start_chat()
    elseif command == "Auth" then
      api.input_auth()
    elseif command == "New" then
      api.new()
    elseif command == "Clear" then
      if api.clear then
        api.clear()
      end
    elseif command == "Save" then
      api.save()
    elseif command == "Sessions" then -- select session
      api.select_sessions()
    elseif command == "Delete" then -- delete session
      if api.delete_session then
        api.delete_session()
      end
    elseif command == "Rename" then -- rename session
      if api.rename_session then
        api.rename_session()
      end
    elseif command == "Servers" then
      api.select_server()
    else
      notify.warn "Invalid LLM command"
    end
  end, { desc = "llm chat", nargs = "?" })
end

return M
