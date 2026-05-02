---ProviderManager and ProviderRegistry
-- This module provides centralized provider management and registry functionality.

local config = require "inobit.llm.config"
-- ui module is loaded lazily in open_provider_selector to avoid circular dependency
local util = require "inobit.llm.util"
local notify = require "inobit.llm.notify"

-- Import all provider classes
local Provider = require "inobit.llm.provider.base"
local OpenAIProtocol = require "inobit.llm.provider.openai_protocol"
local OpenRouterProvider = require "inobit.llm.provider.openrouter"
local StandardOpenAIProvider = require "inobit.llm.provider.standard_openai"
local DeepSeekProvider = require "inobit.llm.provider.deepseek"
local DeepLProvider = require "inobit.llm.provider.deepl"
local AliyunProvider = require "inobit.llm.provider.aliyun"
local NvidiaProvider = require "inobit.llm.provider.nvidia"

---@class llm.ProviderClassEntry
---@field class table The provider class

---ProviderRegistry: Maps provider type identifiers to their implementations
---@type table<string, llm.ProviderClassEntry>
local ProviderRegistry = {
  openai = { class = StandardOpenAIProvider },
  openrouter = { class = OpenRouterProvider },
  deepseek = { class = DeepSeekProvider },
  aliyun = { class = AliyunProvider },
  nvidia = { class = NvidiaProvider },
  deepl = { class = DeepLProvider },
}

---ProviderManager: Central management for provider instances and configurations
---@class llm.ProviderManager
---@field provider_configs table<string, llm.config.ProviderEntry> Provider configurations (not instances)
---@field resolved_providers table<string, llm.Provider> Cache of resolved provider instances
---@field scenario_providers table<Scenario, llm.Provider> Provider instances per scenario
local ProviderManager = {}
ProviderManager.__index = ProviderManager

---Get the default model for a provider based on scenario type.
---Priority: scenario_models[scenario] → default_model
---@param provider_name string The provider name
---@param scenario? Scenario The usage scenario
---@return string model_id The default model ID
function ProviderManager:_get_default_model(provider_name, scenario)
  local provider_config = self.provider_configs[provider_name]
  if not provider_config then
    error("Unknown provider: " .. provider_name)
  end

  local model_id

  -- Check scenario_models for scenario-specific model
  if scenario and provider_config.scenario_models and provider_config.scenario_models[scenario] then
    model_id = provider_config.scenario_models[scenario]
  else
    model_id = provider_config.default_model
  end

  if not model_id then
    error("Provider " .. provider_name .. " has no default_model configured")
  end
  return model_id
end

---Get supported scenarios from provider config.
---Returns "all" or array of scenarios. Default is "all" if not configured.
---@param provider_config llm.config.ProviderEntry
---@return SupportsScenarios
local function get_supported_scenarios(provider_config)
  if provider_config.supports_scenarios then
    return provider_config.supports_scenarios
  end
  -- Default to all scenarios if not configured
  return "all"
end

---Check if a provider supports a specific scenario.
---@param provider_name string The provider name
---@param scenario Scenario The scenario to check
---@return boolean
function ProviderManager:provider_supports_scenario(provider_name, scenario)
  local provider_config = self.provider_configs[provider_name]
  if not provider_config then
    return false
  end

  -- Check supports_scenarios from config
  local scenarios = get_supported_scenarios(provider_config) --[[@as "all" | Scenario[] ]]
  if scenarios == "all" then
    return true
  end
  ---@cast scenarios Scenario[]
  for _, s in ipairs(scenarios) do
    if s == scenario then
      return true
    end
  end

  return false
end

---Get all providers that support a specific scenario.
---@param scenario Scenario The scenario filter
---@return string[] provider_names List of provider names
function ProviderManager:get_providers_for_scenario(scenario)
  local result = {}
  for name, _ in pairs(self.provider_configs) do
    if self:provider_supports_scenario(name, scenario) then
      table.insert(result, name)
    end
  end
  table.sort(result)
  return result
end

---Get the appropriate provider class based on provider name.
---@param provider_name string The provider name
---@return table provider_class The provider class to instantiate
function ProviderManager:_get_provider_class(provider_name)
  local name_lower = provider_name:lower()

  -- Check registry by provider name
  local registry_entry = ProviderRegistry[name_lower]
  if registry_entry then
    return registry_entry.class
  end

  error("Unsupported provider: " .. provider_name .. ". Please register a custom provider class.")
end

---Resolve a provider with model-specific overrides applied.
---Results are cached in resolved_providers table.
---@param provider_name string The provider name (e.g., "OpenRouter")
---@param model_id string The model ID to use
---@param scenario? Scenario The usage scenario (optional)
---@return llm.Provider The resolved provider instance
function ProviderManager:resolve_provider(provider_name, model_id, scenario)
  local cache_key = provider_name .. "@" .. model_id

  -- Return cached instance if available (use rawget to avoid __index recursion)
  local cached = rawget(self.resolved_providers, cache_key)
  if cached then
    return cached
  end

  -- Get the provider entry from config
  local provider_entry = self.provider_configs[provider_name]
  if not provider_entry then
    error("Unknown provider: " .. provider_name)
  end

  -- Build resolved config with only needed fields
  local resolved_config = {
    base_url = provider_entry.base_url,
    api_key_name = provider_entry.api_key_name,
    params = provider_entry.params or {},
  }

  -- Apply model-specific parameter overrides if they exist
  local model_overrides = config.normalize_model_overrides(provider_entry.model_overrides)
  if model_overrides[model_id] then
    resolved_config.params = vim.tbl_deep_extend("force", resolved_config.params, model_overrides[model_id])
  end

  -- Set the model and provider name
  resolved_config.model = model_id
  resolved_config.provider = provider_name

  -- Create the appropriate provider instance
  local ProviderClass = self:_get_provider_class(provider_name)
  local instance = ProviderClass:new(resolved_config)

  -- Cache and return the instance
  self.resolved_providers[cache_key] = instance
  return instance
end

---Set default providers for all scenarios.
---Uses scenario_defaults if specified, otherwise applies fallback strategy.
function ProviderManager:set_default_providers()
  local scenario_defaults = config.options.scenario_defaults or {}
  self.scenario_providers = {}

  for _, scenario in pairs(config.Scenario) do
    local provider_name = self:_find_provider_for_scenario(scenario, scenario_defaults[scenario])
    local model_id = self:_get_model_for_scenario(provider_name, scenario)
    self.scenario_providers[scenario] = self:resolve_provider(provider_name, model_id, scenario)
  end
end

---Find the best provider for a scenario using fallback strategy.
---1. If specified in scenario_defaults, use it
---2. Find first provider with API key that supports the scenario
---3. Find first provider that supports the scenario
---@param scenario Scenario The scenario
---@param default_name? string Provider name from scenario_defaults
---@return string provider_name
function ProviderManager:_find_provider_for_scenario(scenario, default_name)
  -- 1. Use scenario_defaults if specified
  if default_name and self.provider_configs[default_name] then
    return default_name
  end

  -- 2. Find first provider with API key that supports the scenario
  for name, entry in pairs(self.provider_configs) do
    if self:provider_supports_scenario(name, scenario) then
      -- If no api_key_name is configured, skip API key check
      if not entry.api_key_name then
        return name
      end
      local api_key = vim.fn.getenv(entry.api_key_name)
      if api_key and api_key ~= vim.NIL and api_key ~= "" then
        return name
      end
    end
  end

  -- 3. Find first provider that supports the scenario (regardless of API key)
  for name, entry in pairs(self.provider_configs) do
    if self:provider_supports_scenario(name, scenario) then
      return name
    end
  end

  error("No provider found for scenario: " .. scenario)
end

---Get the model for a provider and scenario.
---Priority: scenario_models[scenario] → default_model
---@param provider_name string The provider name
---@param scenario Scenario The scenario
---@return string model_id
function ProviderManager:_get_model_for_scenario(provider_name, scenario)
  local provider_config = self.provider_configs[provider_name]
  if not provider_config then
    error("Unknown provider: " .. provider_name)
  end

  -- Check scenario_models first
  if provider_config.scenario_models and provider_config.scenario_models[scenario] then
    return provider_config.scenario_models[scenario]
  end

  -- Fall back to default_model (required)
  if not provider_config.default_model then
    error("Provider " .. provider_name .. " has no default_model configured")
  end
  return provider_config.default_model
end

---@param type? Scenario
---@return string[]
function ProviderManager:provider_selector(type)
  if type == "chat" then
    return vim.tbl_filter(function(v)
      return self:provider_supports_scenario(v, "chat")
    end, vim.tbl_keys(self.provider_configs))
  else
    -- all for translate type
    return vim.tbl_keys(self.provider_configs)
  end
end

---Open a provider selector window.
---@param type Scenario
---@param callback? fun(provider: llm.Provider)
function ProviderManager:open_provider_selector(type, callback)
  -- Lazy load ui module to avoid circular dependency
  local ui = require "inobit.llm.ui"
  local providers = self:provider_selector(type)
  table.sort(providers)
  ui.PickerWin:new {
    title = string.format("select %s provider", type),
    items = providers,
    on_change = function(input)
      return util.data_filter(input, providers)
    end,
    on_select = function(selected)
      local provider_config = self.provider_configs[selected]
      local model_id = provider_config.default_model
      if not model_id then
        notify.error("Provider " .. selected .. " has no default_model configured")
        return
      end
      local provider = self:resolve_provider(selected, model_id)
      if type == "chat" then
        self.chat_provider = provider
        notify.info(
          string.format("selected chat provider: %s@%s, does not affect existing sessions!", selected, model_id)
        )
        if callback then
          callback(self.chat_provider)
        end
      elseif type == "translate" then
        self.translate_provider = provider
        notify.info(string.format("selected translate provider: %s@%s", selected, model_id))
        if callback then
          callback(self.translate_provider)
        end
      end
    end,
  }
end

---Initialize the ProviderManager.
---@return llm.ProviderManager
function ProviderManager:init()
  self.provider_configs = config.providers --[[@as table<string, llm.config.ProviderEntry>]]

  -- Set up metatable for auto-resolving on access
  local manager = self
  self.resolved_providers = setmetatable({}, {
    __index = function(_, key)
      -- Parse "Provider@Model" format
      local provider_name, model_id = key:match "^([^@]+)@(.+)$"
      if provider_name and model_id then
        return manager:resolve_provider(provider_name, model_id)
      end
      return nil
    end,
  })

  self:set_default_providers()
  return self
end

---@class llm.ProviderManagerExports: llm.ProviderManager
---@field Provider table
---@field OpenAIProtocol table
---@field OpenRouterProvider table
---@field StandardOpenAIProvider table
---@field DeepSeekProvider table
---@field DeepLProvider table
---@field AliyunProvider table
---@field NvidiaProvider table
---@field ProviderManager table
---@field ProviderRegistry table

local _manager = ProviderManager:init()

---@cast _manager llm.ProviderManagerExports
local manager = _manager

-- Export the module with:
-- 1. The global instance as the main export
-- 2. Class references attached
-- 3. ProviderRegistry for extensibility
manager.Provider = Provider
manager.OpenAIProtocol = OpenAIProtocol
manager.OpenRouterProvider = OpenRouterProvider
manager.StandardOpenAIProvider = StandardOpenAIProvider
manager.DeepSeekProvider = DeepSeekProvider
manager.DeepLProvider = DeepLProvider
manager.AliyunProvider = AliyunProvider
manager.NvidiaProvider = NvidiaProvider
manager.ProviderManager = ProviderManager
manager.ProviderRegistry = ProviderRegistry

return manager
