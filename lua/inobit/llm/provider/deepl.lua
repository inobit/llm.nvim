---@class llm.DeepLProvider: llm.Provider
local DeepLProvider = {}
DeepLProvider.__index = DeepLProvider

-- Inherit from Provider base class
local Provider = require "inobit.llm.provider.base"
setmetatable(DeepLProvider, Provider)

---Create a new DeepLProvider instance
---@param opts llm.provider.ProviderOptions
---@return llm.DeepLProvider
function DeepLProvider:new(opts)
  local instance = Provider.new(self, opts) --[[@as llm.DeepLProvider]]
  instance.auth_prefix = "DeepL-Auth-Key "
  return setmetatable(instance, self)
end

---Build request body for DeepL API
---@param text string The text to translate
---@param params? table Parameters including target_lang, source_lang, formality
---@return table
function DeepLProvider:build_request_body(text, params)
  local body = {
    text = { text },
    target_lang = params and params.target_lang or "EN",
  }

  -- Add optional parameters
  if params then
    if params.source_lang then
      body.source_lang = params.source_lang
    end
    if params.formality then
      body.formality = params.formality
    end
  end

  return body
end

---Build complete request options for HTTP call
---@param body table
---@return llm.provider.RequestOpts|nil opts or nil if API key required but not provided
function DeepLProvider:build_request_opts(body)
  local headers = self:build_headers()
  if not headers then
    return nil
  end
  return {
    url = self.base_url,
    method = "POST",
    body = vim.fn.json_encode(body),
    headers = headers,
  }
end

---Parse non-streaming response from DeepL API
---Supports both official DeepL format and custom service format
---Returns llm.provider.ParsedResult compatible structure
---@param data llm.provider.Response
---@return boolean ok Whether parsing succeeded
---@return llm.provider.ParsedResult result llm.provider.ParsedResult with content, is_complete, and extras
function DeepLProvider:parse_response(data)
  local ok, body = pcall(vim.json.decode, data.body)
  if not ok then
    return false, { error = "failed to parse response", is_complete = true }
  end

  -- Check for OpenAI-style error response
  if body.error then
    local err_msg = body.error.message or body.error.type or "unknown API error"
    if body.error.code then
      err_msg = string.format("[%s] %s", body.error.code, err_msg)
    end
    return false, { error = err_msg, is_complete = true }
  end

  -- Check business error (code field in body, not 200)
  if body.code and body.code ~= 200 then
    return false, {
      error = string.format("API error: %s - %s", body.code, body.message or "unknown"),
      is_complete = true,
    }
  end

  local result = {
    is_complete = true,  -- DeepL always returns complete response
  }

  -- DeepL official API format: translations array
  local translations = body.translations
  if translations and #translations > 0 then
    result.content = translations[1].text
    result.detected_source_language = translations[1].detected_source_language
    return true, result
  end

  -- Custom service format: data field with optional alternatives
  if body.data then
    result.content = body.data
    result.alternatives = body.alternatives
    return true, result
  end

  return false, { error = "no content in response", is_complete = true }
end

---Parse a streaming chunk from the API
---DeepL API does not support streaming, so this always returns ok=true, nil
---@param chunk string
---@return boolean ok Always true (no error)
---@return nil
function DeepLProvider:parse_stream_chunk(chunk) ---@diagnostic disable-line: unused-local
  -- DeepL does not support streaming
  return true, nil
end

return DeepLProvider
