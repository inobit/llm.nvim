local M = {}
local ChatManager = require "inobit.llm.chat"
local SessionManager = require "inobit.llm.session"
local ServerManager = require "inobit.llm.server"
local translate = require "inobit.llm.translate"

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
  end, function(session)
    ChatManager:delete_chat(session)
  end)
end

M.open_chat_server_selector = function()
  ServerManager:open_selector "chat"
end

M.open_translate_server_selector = function()
  ServerManager:open_selector "translate"
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

return M
