---@class llm.CachedModels
---@field models table[] List of model objects
---@field fetched_at number Unix timestamp when models were fetched
---@field provider string Provider name

local io = require "inobit.llm.io"
local log = require "inobit.llm.log"

local M = {}

-- Runtime memory cache (persists during session)
---@type table<string, llm.CachedModels>
local runtime_cache = {}

---@class llm.models.Fetcher
---@field name string Provider name
---@field endpoint string models API endpoint (relative path)
---@field requires_auth? boolean Whether authentication is required
---@field parse_response fun(body: string): string[] Parse response to extract model IDs

---@type table<string, llm.models.Fetcher>
local fetchers = {
  OpenRouter = {
    name = "OpenRouter",
    endpoint = "/models",
    requires_auth = false,
    parse_response = function(body)
      local data = vim.json.decode(body)
      return vim.tbl_map(function(m)
        return m.id
      end, data.data or {})
    end,
  },
  OpenAI = {
    name = "OpenAI",
    endpoint = "/models",
    requires_auth = true,
    parse_response = function(body)
      local data = vim.json.decode(body)
      return vim.tbl_map(function(m)
        return m.id
      end, data.data or {})
    end,
  },
  DeepSeek = {
    name = "DeepSeek",
    endpoint = "/models",
    requires_auth = true,
    parse_response = function(body)
      local data = vim.json.decode(body)
      return vim.tbl_map(function(m)
        return m.id
      end, data.data or {})
    end,
  },
}

---Get the default cache directory for models
---@return string The default cache directory path
function M.get_default_cache_dir()
  return vim.fn.stdpath "cache" .. "/inobit/llm/models"
end

---Get cached models from a cache file
---@param path string The path to the cache file
---@return llm.CachedModels|nil cached The cached models data, or nil if not found
---@return string|nil err Error code if failed
function M.get_cached_models(path)
  local data, err = io.read_json(path)
  if err then
    return nil, err
  end
  return data, nil
end

---Save models to a cache file
---@param path string The path to the cache file
---@param data llm.CachedModels The models data to cache
---@return number|nil size Number of bytes written on success, nil on failure
---@return string|nil err Error message if failed
function M.save_models_cache(path, data)
  return io.write_json(path, data)
end

---Check if a cache file is still valid based on TTL
---@param path string The path to the cache file
---@param ttl number Time-to-live in seconds
---@return boolean valid True if cache is valid, false otherwise
function M.is_cache_valid(path, ttl)
  local data, err = M.get_cached_models(path)
  if err then
    return false
  end

  ---@cast data llm.CachedModels
  local current_time = os.time()
  local elapsed = current_time - data.fetched_at

  return elapsed <= ttl
end

---Get fetcher for a provider
---@param provider_name string Provider name
---@return llm.models.Fetcher fetcher The fetcher for the provider
function M.get_fetcher(provider_name)
  local fetcher = fetchers[provider_name]
  if fetcher then
    return fetcher
  end
  -- Default OpenAI-compatible fetcher
  return {
    name = provider_name,
    endpoint = "/models",
    requires_auth = true,
    parse_response = function(body)
      local data = vim.json.decode(body)
      return vim.tbl_map(function(m)
        return m.id
      end, data.data or {})
    end,
  }
end

---Build models API URL from provider config
---@param provider_config table Provider configuration with base_url
---@return string url The models API URL
function M.build_models_url(provider_config)
  -- base_url goes to /v1, append /models endpoint
  return provider_config.base_url .. "/models"
end

---Fetch models from provider API
---@param provider_config table Provider configuration
---@param callback fun(models: table[]?, error: string?) Callback with models or error
---@return vim.SystemObj? job The system job object
function M.fetch_models(provider_config, callback)
  local fetcher = M.get_fetcher(provider_config.provider)
  local url = M.build_models_url(provider_config)

  local headers = {}
  if fetcher.requires_auth then
    local api_key = vim.fn.getenv(provider_config.api_key_name)
    if not api_key or api_key == vim.NIL then
      callback(nil, "API key not set: " .. provider_config.api_key_name)
      return nil
    end
    headers = { "Authorization: Bearer " .. api_key }
  end

  local cmd = { "curl", "-sS", "-X", "GET", "-H", "Content-Type: application/json" }
  for _, h in ipairs(headers) do
    table.insert(cmd, "-H")
    table.insert(cmd, h)
  end
  table.insert(cmd, url)

  return vim.system(cmd, {}, function(result)
    if result.code ~= 0 then
      callback(nil, "curl failed: " .. result.stderr)
      return
    end

    local ok, model_ids = pcall(fetcher.parse_response, result.stdout)
    if not ok then
      callback(nil, "parse error: " .. model_ids)
      return
    end

    local models_list = vim.tbl_map(function(id)
      return { id = id }
    end, model_ids)

    callback(models_list, nil)
  end)
end

---Get models for a provider (uses cache if valid, otherwise fetches)
---Priority: runtime memory cache → disk cache → API fetch
---@param provider_name string Provider name
---@param provider_config table Provider configuration
---@param callback fun(models: table[]) Callback with models list
function M.get_models(provider_name, provider_config, callback)
  local ttl = (provider_config.cache_ttl or 24) * 3600 -- Convert hours to seconds

  -- 1. Check runtime memory cache first (fastest)
  local runtime_cached = runtime_cache[provider_name]
  if runtime_cached and runtime_cached.models then
    local elapsed = os.time() - runtime_cached.fetched_at
    if elapsed <= ttl then
      callback(runtime_cached.models)
      return
    end
  end

  -- 2. Check disk cache
  local cache_path = M.get_default_cache_dir() .. "/" .. provider_name:lower() .. ".json"
  if M.is_cache_valid(cache_path, ttl) then
    local cached = M.get_cached_models(cache_path)
    if cached and cached.models then
      -- Update runtime cache from disk
      runtime_cache[provider_name] = cached
      callback(cached.models)
      return
    end
  end

  -- 3. Fetch from API
  M.fetch_models(provider_config, function(models_list, error)
    if error then
      log.warn("Failed to fetch models: " .. error)
      -- Return empty list on error, caller should fallback to model_overrides
      callback {}
      return
    end

    if models_list and #models_list > 0 then
      local cached_data = {
        models = models_list,
        fetched_at = os.time(),
        provider = provider_name,
      }
      -- Save to both caches
      M.save_models_cache(cache_path, cached_data)
      runtime_cache[provider_name] = cached_data
    end

    callback(models_list or {})
  end)
end

return M
