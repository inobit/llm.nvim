local M = {}

local Path = require "plenary.path"

---@alias ProviderType "chat" | "translate"

---@class llm.provider.BaseOptions
---@field stream? boolean          -- API: enable streaming response
---@field temperature? number      -- API: sampling temperature (0-2), lower=focused, higher=random
---@field max_tokens? number       -- API: max output tokens limit
---@field multi_round? boolean     -- Internal: enable multi-round conversation
---@field user_role? string        -- Internal: role name for user messages

---BaseOptions fields that should be passed to API request body
---Note: multi_round and user_role are internal plugin params, not sent to API
---@type string[]
M.BASE_OPTIONS_FIELDS = { "stream", "temperature", "max_tokens" }

---@class llm.provider.CommonOptions: llm.provider.BaseOptions
---@field base_url string
---@field api_key_name string
---@field provider_type ProviderType  -- Required: "chat" or "translate"

---@class llm.provider.ProviderOptions: llm.provider.CommonOptions
---@field provider string
---@field model string

---@class llm.config.ModelOverride: llm.provider.BaseOptions
-- Note: model ID is the key in model_overrides table, no need for model field here

---@class llm.config.ProviderEntry: llm.provider.CommonOptions
---@field provider string
---@field provider_type ProviderType  -- Required: "chat" or "translate"
---@field default_model string  -- Required: General default model (fallback for chat/translate)
---@field default_chat_model? string  -- Default model for chat (falls back to default_model)
---@field default_translate_model? string  -- Default model for translate (falls back to default_model)
---@field model_overrides? table<string, llm.config.ModelOverride> | string[]  -- Can be table with configs or just model ID list
---@field fetch_models? boolean
---@field cache_ttl? number  -- Cache duration in hours (default: 24)

---Normalize model_overrides to table format
---@param model_overrides table<string, llm.config.ModelOverride> | string[]?
---@return table<string, llm.config.ModelOverride> normalized table with model IDs as keys
function M.normalize_model_overrides(model_overrides)
  if not model_overrides then
    return {}
  end

  -- Check if it's an array format (string[])
  if #model_overrides > 0 and type(model_overrides[1]) == "string" then
    local normalized = {}
    for _, model_id in ipairs(model_overrides) do
      normalized[model_id] = {}
    end
    return normalized
  end

  -- Already table format
  return model_overrides
end

---@class llm.WinOptions
---@field width_percentage number
---@field input_height? integer
---@field input_height_percentage? number
---@field content_height_percentage number
---@field winblend integer

---@class llm.VSplitWinOptions
---@field width_percentage number

---@class llm.NavOptions
---@field next_question string
---@field prev_question string

---@class llm.SmartNamingConfig
---@field enabled boolean
---@field model string
---@field max_length number
---@field min_length number
---@field prompt string

---@class llm.Config
---@field providers table<string, llm.config.ProviderEntry>
---@field chat_provider_defaults llm.provider.BaseOptions  -- Global defaults for chat-type providers
---@field translate_provider_defaults? llm.provider.BaseOptions  -- Global defaults for translate-type providers (optional)
---@field default_provider string  -- Provider name only, model comes from provider's default_model
---@field default_chat_provider? string  -- Provider name, defaults to default_provider
---@field default_translate_provider? string  -- Provider name, optional
---@field chat_layout "float" | "vsplit"
---@field loading_mark string
---@field user_prompt string
---@field question_hi string | vim.api.keyset.highlight user question highlight, can be highlight group name or color table
---@field data_dir string
---@field session_dir string
---@field config_filename string
---@field chat_win llm.WinOptions
---@field session_picker_win llm.WinOptions
---@field provider_picker_win llm.WinOptions
---@field vsplit_win llm.VSplitWinOptions
---@field nav llm.NavOptions
---@field retry_key string
---@field retry_hint_text string
---@field smart_naming llm.SmartNamingConfig

---@return table<string, llm.config.ProviderEntry>
local function default_providers()
  return {
    OpenRouter = {
      provider = "OpenRouter",
      base_url = "https://openrouter.ai/api/v1",
      provider_type = "chat",
      api_key_name = "OPENROUTER_API_KEY",
      -- stream, temperature, etc. come from chat_provider_defaults
      default_model = "openai/gpt-5.5",
      default_translate_model = "google/gemini-2.0-flash-001",
      fetch_models = true, -- Enable dynamic model fetching
    },
  }
end

function M.defaults()
  return {
    -- Provider name (model comes from provider's default_model)
    default_provider = "OpenRouter",

    -- Global defaults for chat-type providers (can be overridden by provider config and model_overrides)
    -- Only API params here; multi_round and user_role are internal, set elsewhere if needed
    chat_provider_defaults = {
      stream = true, -- Enable streaming for responsive chat
      temperature = 0.7, -- Balanced creativity (0-2 scale)
      max_tokens = 4096, -- Reasonable output limit for most models
    },

    -- Global defaults for translate-type providers (optional, no default config)
    -- translate_provider_defaults = {},

    chat_layout = "float",
    loading_mark = "**Generating response ...**",
    user_prompt = "❯",
    question_hi = "Question",
    retry_key = "r",
    retry_hint_text = " press 'r' to retry",
    data_dir = vim.fn.stdpath "cache" .. "/inobit/llm",
    session_dir = "session",
    chat_win = {
      width_percentage = 0.7,
      content_height_percentage = 0.7,
      input_height_percentage = 0.1,
      winblend = 3,
    },
    session_picker_win = {
      width_percentage = 0.5,
      input_height = 1,
      content_height_percentage = 0.3,
      winblend = 5,
    },
    provider_picker_win = {
      width_percentage = 0.3,
      input_height = 1,
      content_height_percentage = 0.2,
      winblend = 0,
    },
    vsplit_win = {
      width_percentage = 0.45,
    },
    nav = {
      next_question = "]q",
      prev_question = "[q",
    },
    smart_naming = {
      enabled = true,
      model = "OpenRouter@google/gemini-2.5-flash-lite",
      max_length = 15,
      min_length = 20, -- recommended 20
      prompt = "Summarize the topic of this conversation in no more than %d words: %s",
    },
  }
end

---@param user_providers table<string, llm.config.ProviderEntry>?
---@return table<string, llm.config.ProviderEntry>
local function install_providers(user_providers)
  local defaults = default_providers()
  local result = vim.tbl_deep_extend("force", {}, defaults)

  if user_providers and not vim.tbl_isempty(user_providers) then
    for name, entry in pairs(user_providers) do
      if result[name] then
        -- Merge with existing default provider
        result[name] = vim.tbl_deep_extend("force", {}, result[name], entry)
      else
        result[name] = vim.tbl_deep_extend("force", {}, entry)
      end
    end
  end

  return result
end

---@return string
function M.get_session_dir()
  return Path:new(M.options.data_dir, M.options.session_dir).filename
end

---@class llm.SetupOptions
---@field providers? table<string, llm.config.ProviderEntry>
---@field chat_provider_defaults? llm.provider.BaseOptions  -- Global defaults for chat-type providers
---@field translate_provider_defaults? llm.provider.BaseOptions  -- Global defaults for translate-type providers
---@field default_provider? string  -- Provider name only
---@field default_chat_provider? string  -- Provider name
---@field default_translate_provider? string  -- Provider name
---@field chat_layout? "float" | "vsplit"
---@field loading_mark? string
---@field user_prompt? string
---@field question_hi? string | vim.api.keyset.highlight highlight group name, "link:GroupName", or color table
---@field thinking_hi? string | vim.api.keyset.highlight group name or options
---@field data_dir? string
---@field session_dir? string
---@field config_filename? string
---@field chat_win? llm.WinOptions
---@field session_picker_win? llm.WinOptions
---@field provider_picker_win? llm.WinOptions
---@field vsplit_win? llm.VSplitWinOptions
---@field nav? llm.NavOptions
---@field retry_key? string
---@field retry_hint_text? string
---@field smart_naming? llm.SmartNamingConfig

---@param options? llm.SetupOptions
function M.setup(options)
  --TODO: check options,api_key_name
  options = options or {}
  local combined = vim.tbl_deep_extend("force", {}, M.defaults(), options)
  combined.providers = install_providers(combined.providers)

  -- Validate chat_layout
  local valid_layouts = { float = true, vsplit = true }
  if not valid_layouts[combined.chat_layout] then
    error("Invalid chat_layout: " .. tostring(combined.chat_layout) .. ". Must be 'float' or 'vsplit'")
  end

  -- Clamp vsplit_win width_percentage to valid range
  if combined.vsplit_win and combined.vsplit_win.width_percentage then
    if combined.vsplit_win.width_percentage > 0.7 then
      combined.vsplit_win.width_percentage = 0.7
    end
    if combined.vsplit_win.width_percentage < 0.2 then
      combined.vsplit_win.width_percentage = 0.2
    end
  end

  M.options = combined --[[@as llm.Config]]
  M.providers = combined.providers
end

return M
