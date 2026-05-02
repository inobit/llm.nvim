---@class llm.OpenAIProtocol : llm.Provider

---@class llm.DeepSeekProvider: llm.OpenAIProtocol
local DeepSeekProvider = {}
DeepSeekProvider.__index = DeepSeekProvider

-- Inherit from OpenAIProtocol
local OpenAIProtocol = require "inobit.llm.provider.openai_protocol"
setmetatable(DeepSeekProvider, OpenAIProtocol)

---Create a new DeepSeekProvider instance
---@param opts llm.provider.ProviderOptions
---@return llm.DeepSeekProvider
function DeepSeekProvider:new(opts)
  local instance = OpenAIProtocol.new(self, opts) --[[@as llm.DeepSeekProvider]]
  instance.reasoning_field = "reasoning_content"
  return setmetatable(instance, self)
end

return DeepSeekProvider
