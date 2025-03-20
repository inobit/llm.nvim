local M = {}

-- options
function M.setup(opts)
  local config = require "inobit.llm.config"
  config.setup(opts)
  local chat = require "inobit.llm.chat"
  local servers = require "inobit.llm.servers"
  local notify = require "inobit.llm.notify"
  local translate = require "inobit.llm.translate"
  -- ensure default server is selected
  servers.set_server_selected(config.options.default_server)

  vim.api.nvim_create_user_command("LLM", function(options)
    local args = options.fargs
    local command = args[1]
    if command == nil then
      chat.start_chat()
    elseif command == "Chat" then
      chat.start_chat()
    elseif command == "ShutDown" then
      chat.shutdown_chat()
    elseif command == "Auth" then
      chat.input_auth()
    elseif command == "New" then
      chat.new()
    elseif command == "Clear" then
      if chat.clear then
        chat.clear()
      end
    elseif command == "Save" then
      chat.save()
    elseif command == "Sessions" then -- select session
      chat.select_sessions()
    elseif command == "Delete" then -- delete session
      if chat.delete_session then
        chat.delete_session()
      end
    elseif command == "Rename" then -- rename session
      if chat.rename_session then
        chat.rename_session()
      end
    elseif command == "Servers" then
      chat.select_server()
    else
      notify.warn "Invalid LLM command"
    end
  end, { desc = "llm chat", nargs = "?" })

  -- translate command
  vim.api.nvim_create_user_command("TS", function(options)
    local args = options.fargs
    local type = args[1]
    local text = table.concat(args, " ", 2)
    if translate.is_valid_type(type) then
      translate.translate_in_cmdline(text, type)
    else
      translate.translate_in_cmdline(type .. " " .. text)
    end
  end, { desc = "LLM: translate command", nargs = "*" })
end

return M
