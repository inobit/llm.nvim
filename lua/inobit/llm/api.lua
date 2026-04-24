local M = {}
local ChatManager = require "inobit.llm.chat"
local SessionManager = require "inobit.llm.session"
local ProviderManager = require "inobit.llm.provider"
local translate = require "inobit.llm.translate"
local notify = require "inobit.llm.notify"

M.new_chat = function()
  ChatManager:new()
end

---@return integer
M.has_chats = function()
  return ChatManager:has_chats()
end

---@return integer
M.has_active_chats = function()
  return ChatManager:has_active_chats()
end

M.open_session_selector = function()
  SessionManager:open_selector(function(session)
    ChatManager:new(session)
  end, function(session_index, refresh, input_win)
    local chat = ChatManager.chats[session_index.id]

    local function restore_focus()
      if input_win and vim.api.nvim_win_is_valid(input_win.winid) then
        vim.api.nvim_set_current_win(input_win.winid)
      end
    end

    -- Unused, directly deleted
    if not chat then
      session_index:delete(function(_)
        refresh()
        restore_focus()
      end)
      return
    end

    -- Background state, deleted after cleaning up resources
    if not chat:is_foreground() then
      ChatManager:delete_chat(session_index)
      session_index:delete(function(_)
        refresh()
        restore_focus()
      end)
      return
    end

    -- Front status, need to confirm
    vim.ui.input({ prompt = "Session is active in chat. Delete anyway? (Y/N): " }, function(input)
      if input and input:lower() == "y" then
        ChatManager:delete_chat(session_index)
        session_index:delete(function(_)
          notify.info("session deleted", string.format("session %s deleted.", session_index.title))
          refresh()
          restore_focus()
        end)
      else
        notify.info("delete cancelled", "session was not deleted")
        refresh()
        restore_focus()
      end
    end)
  end)
end

M.open_chat_provider_selector = function()
  ProviderManager:open_provider_selector "chat"
end

M.open_translate_provider_selector = function()
  ProviderManager:open_provider_selector "translate"
end

---@param text string
---@param type translate_type
M.translate_in_cmdline = function(text, type)
  if translate.is_valid_type(type) then
    translate.translate_in_cmdline(text, type)
  else
    translate.translate_in_cmdline(type .. " " .. text)
  end
end

M.translate_in_buffer = translate.translate_in_buffer
M.translate_in_lsp = translate.translate_in_lsp

M.is_translating = translate.get_translate_status

M.toggle_chat = function()
  local last_chat = ChatManager.last_used_chat

  -- If there's a foreground chat, close it; otherwise open new (or restore last)
  if last_chat and last_chat:is_foreground() then
    local response_win = last_chat.win.wins.response.winid
    local input_win = last_chat.win.wins.input.winid
    pcall(vim.api.nvim_win_close, input_win, true)
    pcall(vim.api.nvim_win_close, response_win, true)
  else
    ChatManager:new()
  end
end

return M
