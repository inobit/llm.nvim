local M = {}

local Path = require "plenary.path"

---@alias ProviderType "chat" | "translate"

---@class llm.provider.Reasoning
---@field effort? "high" | "medium" | "low"
---@field max_tokens? number
---@field exclude? boolean

---@class llm.provider.BaseOptions
---@field stream? boolean
---@field multi_round? boolean
---@field user_role? string
---@field temperature? number
---@field max_tokens? number
---@field reasoning? llm.provider.Reasoning

---@class llm.provider.CommonOptions: llm.provider.BaseOptions
---@field base_url string
---@field api_key_name string
---@field provider_type? ProviderType

---@class llm.provider.ProviderOptions: llm.provider.CommonOptions
---@field provider string
---@field model string

---@class llm.provider.Model: llm.provider.CommonOptions
---@field model string
---@field base_url? string
---@field api_key_name? string

---@class llm.config.ProviderOptions: llm.provider.CommonOptions
---@field provider string
---@field models (string | llm.provider.Model)[]

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
---@field providers table<string, llm.provider.ProviderOptions>
---@field default_provider string
---@field default_chat_provider? string
---@field default_translate_provider? string
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

---@return llm.config.ProviderOptions[]
local function default_providers()
  return {
    {
      provider = "OpenRouter",
      provider_type = "chat",
      base_url = "https://openrouter.ai/api/v1/chat/completions",
      api_key_name = "OPENROUTER_API_KEY",
      stream = true,
      multi_round = true,
      max_tokens = 4096,
      user_role = "user",
      models = {
        { model = "anthropic/claude-opus-4", temperature = 0.4 },
        { model = "openai/gpt-4.5", temperature = 0.4 },
        { model = "google/gemini-3-pro", max_tokens = 8192, temperature = 0.4 },
        { model = "google/gemini-2.5-flash-lite", max_tokens = 4096, temperature = 0.4 },
      },
    },
  }
end

function M.defaults()
  return {
    -- provider@model
    default_provider = "OpenRouter@openai/gpt-4.5",
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
      winblend = 5,
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

---@param providers llm.config.ProviderOptions[]
---@return llm.provider.ProviderOptions[]
local function flat_providers(providers)
  return vim
    .iter(providers)
    :map(function(item)
      local models = item.models
      --WARNING: change object
      item.models = nil
      return vim
        .iter(models)
        :map(function(model)
          if type(model) == "string" then
            model = { model = model }
          end
          return vim.tbl_deep_extend("force", {}, item, model)
        end)
        :totable()
    end)
    :flatten()
    :totable()
end

---@param providers llm.config.ProviderOptions[]
---@return table<string, llm.provider.ProviderOptions>
local function install_providers(providers)
  providers = providers or {}

  local default_providers_flat = flat_providers(default_providers())
  local map = vim.iter(default_providers_flat):fold({}, function(acc, v)
    acc[v.provider .. "@" .. v.model] = v
    return acc
  end)
  if not vim.tbl_isempty(providers) then
    providers = flat_providers(providers)
    vim.iter(providers):each(function(item)
      map[item.provider .. "@" .. item.model] =
        vim.tbl_deep_extend("force", {}, map[item.provider .. "@" .. item.model] or {}, item)
    end)
  end
  return map
end

---@return string
function M.get_session_dir()
  return Path:new(M.options.data_dir, M.options.session_dir).filename
end

---@class llm.SetupOptions
---@field providers? llm.config.ProviderOptions[]
---@field default_provider? string
---@field default_chat_provider? string
---@field default_translate_provider? string
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
end

return M
