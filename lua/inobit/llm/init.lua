local M = {}

-- options
function M.setup(opts)
  local config = require "inobit.llm.config"
  config.setup(opts)
  local api = require "inobit.llm.api"
  local notify = require "inobit.llm.notify"

  vim.api.nvim_create_user_command("LLM", function(options)
    local args = options.fargs
    local command = args[1]
    if command == "Chat" then
      api.new_chat()
    elseif command == "Toggle" then
      api.toggle_chat()
    elseif command == "Sessions" then
      api.open_session_selector()
    elseif command == "ChatProviders" then
      api.open_chat_provider_selector()
    elseif command == "TSProviders" then
      api.open_translate_provider_selector()
    else
      notify.warn "Invalid LLM command"
    end
  end, { desc = "llm chat", nargs = "?" })

  -- translate command
  vim.api.nvim_create_user_command("TS", function(options)
    local args = options.fargs
    local type = args[1]
    local text = table.concat(args, " ", 2)
    api.translate_in_cmdline(text, type)
  end, { desc = "LLM: translate command", nargs = "*" })
end

return M
