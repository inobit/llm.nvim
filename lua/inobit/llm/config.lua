local M = {}

local Path = require "plenary.path"

---@enum Scenario
M.Scenario = {
  CHAT = "chat",
  TRANSLATE = "translate",
}

---Filetype constant for inobit buffers
M.FILETYPE = "inobit"

---@alias SupportsScenarios "all" | Scenario[]

---ModelOverride: Free-form API parameters for model-specific overrides
---e.g. { temperature = 0.5, max_tokens = 2048 }
---@class llm.config.ModelOverride
---@field [string] any

---@class llm.config.ProviderEntry
---@field base_url string
---@field api_key_name? string
---@field supports_scenarios? SupportsScenarios
---@field scenario_models? table<string, string>
---@field default_model string
---@field model_overrides? table<string, llm.config.ModelOverride> | string[]
---@field fetch_models? boolean
---@field cache_ttl? number
---@field params? table<string, any>  -- Free-form API parameters

---User-facing provider config (allows false for api_key_name)
---@class llm.config.UserProviderEntry : llm.config.ProviderEntry
---@field api_key_name? string | false  -- false means explicitly disabled

---Normalize model_overrides to table format
---Supports both string[] (just model IDs) and table<string, ModelOverride> formats
---ModelOverride is flat, e.g. { temperature = 0.5, max_tokens = 2048 }
---@param model_overrides table<string, llm.config.ModelOverride> | string[]?
---@return table<string, table<string, any>> normalized table with model IDs as keys
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

  -- Table format: return as-is (already flat)
  return model_overrides
end

---@class llm.FloatChatOptions
---@field width_percentage number  -- width percentage (0-1)
---@field winblend number

---@class llm.SplitChatOptions
---@field width_percentage number  -- width percentage (0-1)
---@field winblend number

---@class llm.NavOptions
---@field next_question string
---@field prev_question string

---@class llm.StatusKeymaps
---@field toggle_multi_round string
---@field toggle_show_reasoning string
---@field cycle_user_role string

---@class llm.SmartNamingConfig
---@field enabled boolean
---@field model string
---@field max_length number
---@field min_length number
---@field prompt string

---@class llm.ScenarioDefaults
---@field chat? string  -- Default provider name for chat scenario
---@field translate? string  -- Default provider name for translate scenario

---@class llm.Config
---@field providers table<string, llm.config.ProviderEntry>
---@field scenario_defaults llm.ScenarioDefaults
---@field chat_layout "float" | "vsplit"
---@field loading_mark string
---@field user_prompt string
---@field question_hi string | vim.api.keyset.highlight user question highlight, can be highlight group name or color table
---@field reasoning_hi? string | vim.api.keyset.highlight reasoning/thinking content highlight
---@field reasoning_icon? string icon for reasoning block header (default: "💭")
---@field reasoning_border? string border character for reasoning block (default: "│")
---@field response_hi? string | vim.api.keyset.highlight response content highlight
---@field error_hi? string | vim.api.keyset.highlight error message highlight
---@field warning_hi? string | vim.api.keyset.highlight warning/cancel message highlight
---@field data_dir string
---@field session_dir string
---@field config_filename string
---@field float_chat llm.FloatChatOptions
---@field split_chat llm.SplitChatOptions
---@field nav llm.NavOptions
---@field retry_key string
---@field retry_hint_text string
---@field smart_naming llm.SmartNamingConfig
---@field status_keymaps llm.StatusKeymaps

---@return table<string, llm.config.ProviderEntry>
local function default_providers()
  return {
    -- OpenRouter: Supports all scenarios with model fetching
    OpenRouter = {
      base_url = "https://openrouter.ai/api/v1",
      api_key_name = "OPENROUTER_API_KEY",
      supports_scenarios = "all",
      scenario_models = {
        chat = "openai/gpt-5.5",
        translate = "google/gemini-2.0-flash-001",
      },
      default_model = "openai/gpt-5.5",
      fetch_models = true,
      params = {
        temperature = 0.6,
        max_tokens = 4096,
      },
    },

    -- OpenAI: Standard OpenAI API
    OpenAI = {
      base_url = "https://api.openai.com/v1",
      api_key_name = "OPENAI_API_KEY",
      supports_scenarios = "all",
      default_model = "gpt-5.5",
      fetch_models = true,
      params = {
        temperature = 0.6,
        max_tokens = 4096,
      },
    },

    -- DeepSeek: Chinese AI model provider
    DeepSeek = {
      base_url = "https://api.deepseek.com/v1",
      api_key_name = "DEEPSEEK_API_KEY",
      supports_scenarios = "all",
      default_model = "deepseek-v4-pro",
      fetch_models = true,
      params = {
        temperature = 0.6,
        max_tokens = 16384,
      },
    },

    -- Aliyun DashScope: Chinese cloud AI service
    Aliyun = {
      base_url = "https://dashscope.aliyuncs.com/compatible-mode/v1",
      api_key_name = "ALIYUN_API_KEY",
      supports_scenarios = "all",
      default_model = "kimi-k2.5",
      fetch_models = false,
      params = {
        temperature = 0.6,
        max_tokens = 16384,
      },
      model_overrides = {
        "glm-5",
        "kimi-k2.5",
      },
    },

    -- NVIDIA: AI model hosting platform
    Nvidia = {
      base_url = "https://integrate.api.nvidia.com/v1",
      api_key_name = "NVIDIA_API_KEY",
      supports_scenarios = "all",
      default_model = "deepseek-ai/deepseek-v4-pro",
      fetch_models = true,
      params = {
        temperature = 0.6,
        max_tokens = 16384,
      },
    },

    -- DeepL: Translation service
    DeepL = {
      base_url = "https://api-free.deepl.com/v2",
      api_key_name = "DEEPL_API_KEY",
      supports_scenarios = { "translate" },
      default_model = "deepl",
      fetch_models = false,
    },
  }
end

function M.defaults()
  return {
    scenario_defaults = {
      chat = "OpenRouter",
      translate = "OpenRouter",
    },
    chat_layout = "vsplit",
    loading_mark = "**Generating response ...**",
    user_prompt = "❯",
    question_hi = "Question",
    reasoning_hi = "Comment", -- Thinking content (dimmed)
    reasoning_icon = "💭", -- Icon for reasoning block header
    reasoning_border = "│", -- Left border character for reasoning content
    response_hi = "Normal", -- Normal response content
    error_hi = "ErrorMsg", -- Error messages (red)
    warning_hi = "WarningMsg", -- Warning/cancel messages (yellow)
    retry_key = "r",
    retry_hint_text = " press 'r' to retry",
    data_dir = vim.fn.stdpath "cache" .. "/inobit/llm",
    session_dir = "session",
    float_chat = {
      width_percentage = 0.7,
      winblend = 3,
    },
    split_chat = {
      width_percentage = 0.45,
      winblend = 0,
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
    status_keymaps = {
      toggle_multi_round = "<A-m>",
      toggle_show_reasoning = "<A-r>",
      cycle_user_role = "<A-l>",
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
---@field providers? table<string, llm.config.UserProviderEntry>
---@field scenario_defaults? llm.ScenarioDefaults
---@field chat_layout? "float" | "vsplit"
---@field loading_mark? string
---@field user_prompt? string
---@field question_hi? string | vim.api.keyset.highlight highlight group name, "link:GroupName", or color table
---@field reasoning_hi? string | vim.api.keyset.highlight thinking/reasoning content highlight
---@field response_hi? string | vim.api.keyset.highlight response content highlight
---@field error_hi? string | vim.api.keyset.highlight error message highlight
---@field warning_hi? string | vim.api.keyset.highlight warning/cancel message highlight
---@field data_dir? string
---@field session_dir? string
---@field config_filename? string
---@field float_chat? llm.FloatChatOptions
---@field split_chat? llm.SplitChatOptions
---@field nav? llm.NavOptions
---@field retry_key? string
---@field retry_hint_text? string
---@field smart_naming? llm.SmartNamingConfig
---@field status_keymaps? llm.StatusKeymaps

---Validate the configuration
---@param options table
---@return boolean valid, string? error
local function validate_config(options)
  -- Validate providers exist
  if not options.providers or vim.tbl_isempty(options.providers) then
    return false, "At least one provider must be configured"
  end

  -- Validate each provider has required fields
  for name, entry in pairs(options.providers) do
    if not entry.base_url then
      return false, string.format("Provider '%s' is missing required field: base_url", name)
    end
    if not entry.default_model then
      return false, string.format("Provider '%s' is missing required field: default_model", name)
    end
    -- api_key_name is optional - if explicitly set to false, convert to nil
    if entry.api_key_name == false then
      entry.api_key_name = nil
    end
  end

  -- Validate chat_layout
  local valid_layouts = { float = true, vsplit = true }
  if not valid_layouts[options.chat_layout] then
    return false, "Invalid chat_layout: " .. tostring(options.chat_layout) .. ". Must be 'float' or 'vsplit'"
  end

  -- Validate and clamp split_chat width_percentage
  if options.split_chat then
    if options.split_chat.width_percentage > 0.7 then
      options.split_chat.width_percentage = 0.7
    end
    if options.split_chat.width_percentage < 0.2 then
      options.split_chat.width_percentage = 0.2
    end
  end

  return true
end

---@param options? llm.SetupOptions
function M.setup(options)
  options = options or {}

  local combined = vim.tbl_deep_extend("force", {}, M.defaults(), options)
  combined.providers = install_providers(combined.providers)

  -- Validate configuration
  local valid, err = validate_config(combined)
  if not valid then
    error("Configuration error: " .. err)
  end

  M.options = combined --[[@as llm.Config]]

  M.providers = combined.providers

  -- Setup highlight groups globally
  -- This ensures highlights are available when inobit buffers are loaded
  local hl_ok, hl = pcall(require, "inobit.llm.highlights")
  if hl_ok then
    hl.setup_inobit_highlights()
  end
end

return M
