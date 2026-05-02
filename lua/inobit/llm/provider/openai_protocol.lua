---@class llm.OpenAIProtocol: llm.Provider
---@field reasoning_field? string Field name for reasoning content in responses
local OpenAIProtocol = {}
OpenAIProtocol.__index = OpenAIProtocol

-- Inherit from Provider base class
local Provider = require "inobit.llm.provider.base"
setmetatable(OpenAIProtocol, Provider)

---Create a new OpenAIProtocol instance
---@param opts llm.provider.ProviderOptions
---@return llm.OpenAIProtocol
function OpenAIProtocol:new(opts)
  local instance = Provider.new(self, opts) --[[@as llm.OpenAIProtocol]]
  -- Explicitly set to nil (subclasses can override to enable reasoning)
  instance.reasoning_field = instance.reasoning_field or nil
  return setmetatable(instance, self)
end

---Build request body for OpenAI format API
---Merges provider's self.params with call-time params (call-time takes precedence)
---@param messages table[] Array of message objects with role and content
---@param params? table<string, any> Call-time API parameters
---@return table
function OpenAIProtocol:build_request_body(messages, params)
  -- Merge: base body <- provider params <- call-time params
  local body = vim.tbl_deep_extend("force", {
    model = self.model,
    messages = messages,
  }, self.params or {}, params or {})

  return body
end

---Get the endpoint path for chat completions
---@return string
function OpenAIProtocol:get_endpoint()
  return "/chat/completions"
end

---Build complete request options for HTTP call
---@param body table
---@return llm.provider.RequestOpts|nil opts or nil if API key required but not provided
function OpenAIProtocol:build_request_opts(body)
  local headers = self:build_headers()
  if not headers then
    return nil
  end
  return {
    url = self.base_url .. self:get_endpoint(),
    method = "POST",
    body = vim.fn.json_encode(body),
    headers = headers,
  }
end

---Extract field from delta object with vim.NIL handling
---@param delta table The delta object
---@param field_name string The field name to extract
---@return string|nil
function OpenAIProtocol:extract_field(delta, field_name)
  if not field_name then
    return nil
  end
  local value = delta[field_name]
  if value == nil or value == vim.NIL or value == "" then
    return nil
  end
  return value
end

---Extract reasoning field from delta object
---@param delta table The delta object from stream chunk
---@return string|nil
function OpenAIProtocol:extract_reasoning_field(delta)
  if not self.reasoning_field then
    return nil
  end
  return self:extract_field(delta, self.reasoning_field)
end

---Parse non-streaming response from API
---Returns llm.provider.ParsedResult compatible structure
---@param data llm.provider.Response
---@return boolean ok Whether parsing succeeded
---@return llm.provider.ParsedResult result Contains content, reasoning_content, and is_complete
function OpenAIProtocol:parse_response(data)
  local ok, body = pcall(vim.json.decode, data.body)
  if not ok then
    return false, { error = "failed to parse response" }
  end

  -- Check for API error response
  if body.error then
    local err_msg = body.error.message or body.error.type or "unknown API error"
    if body.error.code then
      err_msg = string.format("[%s] %s", body.error.code, err_msg)
    end
    return false, { error = err_msg }
  end

  -- Check choices exists and is not empty
  local choices = body.choices
  if not choices or #choices == 0 then
    return false, { error = "no choices in response" }
  end

  local choice = choices[1]
  if not choice then
    return false, { error = "empty first choice" }
  end

  -- Check message exists
  if not choice.message then
    return false, { error = "no message in choice" }
  end

  local result = {}
  local message = choice.message

  -- Extract content using extract_field helper
  local content = self:extract_field(message, "content")
  if content then
    result.content = content
  end

  -- Extract reasoning content if reasoning_field is configured
  local reasoning_content = self:extract_reasoning_field(message)
  if reasoning_content then
    result.reasoning_content = reasoning_content
  end

  -- Set is_complete flag for non-streaming response
  result.is_complete = true

  -- At least one of content or reasoning_content should exist
  if not result.content and not result.reasoning_content then
    return false, { error = "no content or reasoning in response" }
  end

  return true, result
end

---Parse a streaming chunk from the API (SSE format)
---Returns llm.provider.ParsedResult compatible structure
---@param chunk string
---@return boolean ok Whether parsing succeeded
---@return llm.provider.ParsedResult|nil result Chunk data, or nil for [DONE] if ok=true, or error info if ok=false
function OpenAIProtocol:parse_stream_chunk(chunk)
  -- Check for [DONE] signal
  if chunk == "[DONE]" or chunk == "data: [DONE]" then
    return true, nil
  end

  -- SSE heartbeat/ping comments start with ":"
  -- These should be ignored silently
  if chunk:match "^:" then
    return true, nil
  end

  -- Empty lines are also valid in SSE (heartbeats)
  if chunk == "" then
    return true, nil
  end

  -- Try to parse as SSE data format: "data: {...}"
  local data = chunk:match "^data:%s*(.+)$"

  -- If not SSE format, try to parse the whole chunk as JSON (error response)
  if not data then
    -- Check if this is a plain JSON error response
    local ok, parsed = pcall(vim.json.decode, chunk)
    if ok and parsed.error then
      local err_msg = parsed.error.message or parsed.error.type or "unknown API error"
      if parsed.error.code then
        err_msg = string.format("[%s] %s", parsed.error.code, err_msg)
      end
      return false, { error = err_msg }
    end
    -- Not SSE and not valid JSON error, treat as invalid format
    return false, { error = "invalid SSE format" }
  end

  -- Try to parse JSON from SSE data
  local ok, parsed = pcall(vim.json.decode, data)
  if not ok then
    return false, { error = "JSON parse error: " .. tostring(parsed) }
  end

  -- Check for API error response in SSE data
  if parsed.error then
    local err_msg = parsed.error.message or parsed.error.type or "unknown API error"
    if parsed.error.code then
      err_msg = string.format("[%s] %s", parsed.error.code, err_msg)
    end
    return false, { error = err_msg }
  end

  -- Extract delta from choices
  local delta = vim.tbl_get(parsed, "choices", 1, "delta")
  if not delta then
    -- Check for usage-only chunk (end of stream) or finish_reason without delta
    if parsed.usage or vim.tbl_get(parsed, "choices", 1, "finish_reason") then
      return true, nil
    end
    return false, { error = "no delta in chunk" }
  end

  -- Delta may be empty {} or have no content (finish_reason signal)
  -- This is normal - just return empty result
  local result = {}

  -- Extract content (may be null or missing)
  result.content = self:extract_field(delta, "content")

  -- Check if this is the final chunk (finish_reason present but no content)
  -- finish_reason values: "stop", "length", "content_filter", "tool_calls", null
  local finish_reason = vim.tbl_get(parsed, "choices", 1, "finish_reason")
  if finish_reason and finish_reason ~= vim.NIL and not result.content then
    -- This is a finish signal, treat as stream end
    return true, nil
  end

  -- Extract reasoning content if configured
  result.reasoning_content = self:extract_reasoning_field(delta)

  return true, result
end

return OpenAIProtocol
