---@diagnostic disable: unused-local

local notify = require "inobit.llm.notify"

---@class llm.provider.RequestOpts
---@field callback? fun(data: llm.provider.Response)    -- 正常完成
---@field cancel? fun(reason: string)                   -- 用户取消 (signal=9)
---@field on_error? fun(err: llm.provider.Error)        -- API 错误
---@field stream? fun(error: string, data: string)
---@field url string
---@field method? string
---@field body? string
---@field headers? table<string, string>

---@class llm.provider.Error
---@field message string
---@field stderr? string

---@class llm.provider.Response
---@field status number
---@field headers string[]
---@field body string

---@class llm.provider.ParsedResult
--- Generic parsed result from provider, subclasses may extend with additional fields
---@field content? string              -- Content fragment or complete content
---@field reasoning_content? string    -- Reasoning content (if reasoning_field is configured)
---@field finish_reason? string        -- "stop", "length", "content_filter", null
---@field is_complete? boolean         -- true for non-streaming, nil/false for streaming
---@field error? string                -- Error message
---@field [string] any                 -- Extension fields for subclasses

---@class llm.RequestJob
---@field _job vim.SystemObj
---@field cancel fun(self: llm.RequestJob, reason?: string) -- 发送 SIGKILL，触发 cancel 回调
---@field is_active fun(self: llm.RequestJob): boolean
---@field pid number?

---Provider configuration options
---@class llm.provider.ProviderOptions
---@field provider string           -- Provider name (e.g., "OpenRouter", "DeepSeek")
---@field model string              -- Model ID (e.g., "gpt-4", "deepseek-chat")
---@field base_url string           -- API base URL
---@field api_key_name string?       -- Environment variable name for API key
---@field params? table<string, any>  -- Free-form API parameters (temperature, max_tokens, etc.)
---@field auth_prefix? string       -- Authorization header prefix (default: "Bearer")

---@class llm.Provider: llm.provider.ProviderOptions
local Provider = {}
Provider.__index = Provider

---Required fields for provider creation
---@type string[]
local REQUIRED_FIELDS = { "base_url", "provider", "model" }

---Create a new Provider instance
---@param opts llm.provider.ProviderOptions
---@return llm.Provider
function Provider:new(opts)
  -- Validate required fields
  for _, field in ipairs(REQUIRED_FIELDS) do
    if opts[field] == nil then
      error(string.format("Provider: missing required field '%s'", field))
    end
  end
  local provider = vim.tbl_deep_extend("force", {}, opts)
  return setmetatable(provider, self)
end

---Check if this provider is an instance of a given class
---@param class llm.Provider
---@return boolean
function Provider:_is_the_class(class)
  local metatable = getmetatable(self)
  if not metatable then
    return false
  elseif not metatable.__index then
    return false
  elseif metatable.__index == class then
    return true
  else
    return metatable.__index:_is_the_class(class)
  end
end

---Check and prompt for API key if not set
---Uses synchronous input (vim.fn.input) since it's called from build_headers
---@return boolean ok whether to continue (false means user cancelled)
---@return string|nil|false auth the API key value, false if not needed, nil if not set but should continue
function Provider:_check_api_key()
  local api_key_name = self.api_key_name
  -- If no api_key_name is configured, skip the check
  if not api_key_name then
    return true, false
  end

  local api_key = vim.fn.getenv(api_key_name)
  if api_key and api_key ~= vim.NIL and api_key ~= "" then
    return true, api_key
  end

  -- Use synchronous input since we need the value immediately
  local input = vim.fn.input("Enter " .. api_key_name .. ": ")
  if input and input ~= "" then
    vim.fn.setenv(api_key_name, input)
    return true, input
  end

  -- User cancelled or empty input
  notify.warn(api_key_name .. " required but not provided. Request cancelled.")
  return false, nil
end

---Build headers for the request
---Subclasses can override auth_prefix or the entire method
---@return table<string, string>|nil headers or nil if user cancelled API key input
function Provider:build_headers()
  -- Check and prompt for API key if needed
  local ok, auth = self:_check_api_key()

  -- If user cancelled the input, return nil to abort the request
  if not ok then
    return nil
  end

  -- Build headers
  local headers = {
    content_type = "application/json",
  }

  -- Add authorization header only if auth is needed (not false)
  if auth ~= false then
    local prefix = self.auth_prefix or "Bearer "
    headers.authorization = prefix .. (auth or "")
  end

  return headers
end

---Buffer stdout data and split by lines for SSE processing
---@param callback fun(error: string?, data: string?)
---@return fun(_: any, data: string?)
function Provider:_make_line_buffer(callback)
  local buffer = ""
  return function(_, data)
    if not data then
      if buffer ~= "" then
        callback(nil, buffer)
      end
      return
    end
    buffer = buffer .. data
    while true do
      local newline_pos = buffer:find "\n"
      if not newline_pos then
        break
      end
      local line = buffer:sub(1, newline_pos - 1)
      buffer = buffer:sub(newline_pos + 1)
      callback(nil, line)
    end
  end
end

---Send HTTP request to provider using vim.system
---@param opts llm.provider.RequestOpts
---@return llm.RequestJob | nil
function Provider:request(opts)
  local body = opts.body
  local headers = opts.headers or {}
  local cmd = {
    "curl",
    "-sS",
    "-N",
    "-X",
    opts.method or "POST",
    "-H",
    "Content-Type: " .. (headers.content_type or "application/json"),
    "-H",
    "Authorization: " .. (headers.authorization or ""),
  }

  if body then
    table.insert(cmd, "-d")
    table.insert(cmd, body)
  end

  table.insert(cmd, opts.url)

  local stream_callback = opts.stream and self:_make_line_buffer(vim.schedule_wrap(opts.stream))
  local error_callback = opts.on_error and vim.schedule_wrap(opts.on_error)
  local cancel_callback = opts.cancel and vim.schedule_wrap(opts.cancel)
  local exit_callback = opts.callback and vim.schedule_wrap(opts.callback)

  local stderr_data = {}

  local wrapper = {}

  local job = vim.system(cmd, {
    stdout = stream_callback,
    stderr = function(_, data)
      if data then
        table.insert(stderr_data, data)
      end
    end,
  }, function(obj)
    -- 根据 signal 区分三种情况：
    -- signal=9: 用户取消 (SIGKILL)
    -- code!=0: API 错误
    -- 正常退出: 完成
    if obj.signal == 9 then
      -- 用户取消
      if cancel_callback then
        cancel_callback(wrapper.cancel_reason or "User canceled")
      end
    elseif obj.code ~= 0 or obj.signal ~= 0 then
      -- API 错误
      if error_callback then
        error_callback {
          message = table.concat(stderr_data, ""),
          stderr = table.concat(stderr_data, ""),
        }
      end
    elseif exit_callback then
      -- 正常完成
      exit_callback {
        status = 200,
        headers = {},
        body = obj.stdout or "",
      }
    end
  end)

  wrapper._job = job
  wrapper.pid = job.pid
  wrapper.cancel_reason = nil

  ---发送 SIGKILL 取消请求，触发 cancel 回调
  ---@param reason? string 取消原因，会传递给 cancel 回调
  function wrapper:cancel(reason)
    self.cancel_reason = reason or "User canceled"
    self._job:kill(9)
  end

  function wrapper:is_active()
    return self._job.pid ~= nil
  end

  return wrapper
end

---Abstract method: Build request body for the API
---Subclasses must implement this method
---@param input any
---@param provider_params? table<string, any> Call-time API parameters
---@return table
function Provider:build_request_body(input, provider_params)
  error "Provider:build_request_body() must be implemented by subclass"
end

---Abstract method: Build request options for the HTTP call
---Subclasses must implement this method
---@param body table
---@return llm.provider.RequestOpts?
function Provider:build_request_opts(body)
  error "Provider:build_request_opts() must be implemented by subclass"
end

---Abstract method: Parse the response from the API
---Subclasses must implement this method
---Returns llm.provider.ParsedResult compatible structure
---@param data llm.provider.Response
---@return boolean ok Whether parsing succeeded
---@return llm.provider.ParsedResult result
function Provider:parse_response(data)
  error "Provider:parse_response() must be implemented by subclass"
end

---Abstract method: Parse a streaming chunk from the API
---Subclasses must implement this method
---Returns llm.provider.ParsedResult compatible structure
---@param chunk string
---@return boolean ok Whether parsing succeeded (true = success, false = error)
---@return llm.provider.ParsedResult|nil result Chunk data or nil for [DONE], error info if ok=false
function Provider:parse_stream_chunk(chunk)
  error "Provider:parse_stream_chunk() must be implemented by subclass"
end

return Provider
