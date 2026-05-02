---@class llm.OpenAIProtocol : llm.Provider

---@class llm.OpenRouterProvider: llm.OpenAIProtocol
local OpenRouterProvider = {}
OpenRouterProvider.__index = OpenRouterProvider

-- Inherit from OpenAIProtocol
local OpenAIProtocol = require "inobit.llm.provider.openai_protocol"
setmetatable(OpenRouterProvider, OpenAIProtocol)

---Create a new OpenRouterProvider instance
---@param opts llm.provider.ProviderOptions
---@return llm.OpenRouterProvider
function OpenRouterProvider:new(opts)
  local instance = OpenAIProtocol.new(self, opts) --[[@as llm.OpenRouterProvider]]
  instance.reasoning_field = "reasoning"
  return setmetatable(instance, self)
end

---Build headers for the request
---@return table<string, string>|nil headers or nil if user cancelled API key input
function OpenRouterProvider:build_headers()
  -- Check and prompt for API key if needed
  local ok, auth = self:_check_api_key()

  -- If user cancelled the input, return nil to abort the request
  if not ok then
    return nil
  end

  -- Build headers
  local headers = {
    content_type = "application/json",
    ["HTTP-Referer"] = "https://inobit.ai",
    ["X-Title"] = "llm.nvim",
  }

  -- Add authorization header only if auth is needed (not false)
  if auth ~= false then
    headers.authorization = "Bearer " .. (auth or "")
  end

  return headers
end

return OpenRouterProvider
