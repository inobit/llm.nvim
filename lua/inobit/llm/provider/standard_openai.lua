---@class llm.OpenAIProtocol : llm.Provider

---@class llm.StandardOpenAIProvider: llm.OpenAIProtocol
local StandardOpenAIProvider = {}
StandardOpenAIProvider.__index = StandardOpenAIProvider

-- Inherit from OpenAIProtocol
local OpenAIProtocol = require "inobit.llm.provider.openai_protocol"
setmetatable(StandardOpenAIProvider, OpenAIProtocol)

---Create a new StandardOpenAIProvider instance
---@param opts llm.provider.ProviderOptions
---@return llm.StandardOpenAIProvider
function StandardOpenAIProvider:new(opts)
  local instance = OpenAIProtocol.new(self, opts) --[[@as llm.StandardOpenAIProvider]]
  instance.reasoning_field = nil
  return setmetatable(instance, self)
end

return StandardOpenAIProvider
