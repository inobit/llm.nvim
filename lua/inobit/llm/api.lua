local M = {}
local ChatManager = require "inobit.llm.chat"
local SessionManager = require "inobit.llm.session"
local ProviderManager = require "inobit.llm.provider"
local translate = require "inobit.llm.translate"
local notify = require "inobit.llm.notify"
local dual_picker = require "inobit.llm.dual_picker"
local models = require "inobit.llm.models"
local config = require "inobit.llm.config"

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
  dual_picker.DualPickerWin:new {
    title = "Select chat provider@model",
    provider_type = "chat",
    on_confirm = function(provider_name, model_id)
      ProviderManager.chat_provider = ProviderManager:resolve_provider(provider_name, model_id)
      notify.info("Selected: " .. provider_name .. "@" .. model_id .. " (does not affect existing sessions)")
    end,
  }
end

M.open_translate_provider_selector = function()
  dual_picker.DualPickerWin:new {
    title = "Select translate provider@model",
    provider_type = "translate",
    on_confirm = function(provider_name, model_id)
      ProviderManager.translate_provider = ProviderManager:resolve_provider(provider_name, model_id)
      notify.info("Selected: " .. provider_name .. "@" .. model_id)
    end,
  }
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

---Refresh models cache for a specific provider or all providers with fetch_models enabled.
---@param provider_name? string Optional provider name to refresh. If nil, refreshes all.
M.refresh_models = function(provider_name)
  local providers_to_refresh = {}

  if provider_name then
    -- Refresh specific provider
    local provider_config = config.providers[provider_name]
    if provider_config and provider_config.fetch_models then
      providers_to_refresh = { provider_name }
    else
      notify.warn("Provider " .. provider_name .. " does not support dynamic model fetch")
      return
    end
  else
    -- Refresh all providers with fetch_models enabled
    for name, p in pairs(config.providers) do
      if p.fetch_models then
        table.insert(providers_to_refresh, name)
      end
    end
  end

  if #providers_to_refresh == 0 then
    notify.info "No providers configured for dynamic model fetch"
    return
  end

  notify.info("Refreshing models for " .. #providers_to_refresh .. " provider(s)...")

  local completed = 0
  for _, name in ipairs(providers_to_refresh) do
    local provider_config = config.providers[name]
    models.fetch_models(provider_config, function(model_list, error)
      vim.schedule(function()
        if error then
          notify.error("Failed to fetch models for " .. name .. ": " .. error)
        elseif model_list and #model_list > 0 then
          local cache_path = models.get_default_cache_dir() .. "/" .. name:lower() .. ".json"
          models.save_models_cache(cache_path, {
            models = model_list,
            fetched_at = os.time(),
            provider = name,
          })
          notify.info("Refreshed " .. #model_list .. " models for " .. name)
        else
          notify.warn("No models returned for " .. name)
        end

        completed = completed + 1
        if completed == #providers_to_refresh then
          notify.info "Model refresh complete"
        end
      end)
    end)
  end
end

return M
