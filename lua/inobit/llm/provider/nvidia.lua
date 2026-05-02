-- NVIDIA API Provider
-- Extends OpenAIProtocol for NVIDIA's API compatibility

local OpenAIProtocol = require "inobit.llm.provider.openai_protocol"

---@class llm.OpenAIProtocol : llm.Provider

---@class llm.NvidiaProvider: llm.OpenAIProtocol
local NvidiaProvider = {}
NvidiaProvider.__index = NvidiaProvider
setmetatable(NvidiaProvider, { __index = OpenAIProtocol })

-- NVIDIA uses standard OpenAI response format
NvidiaProvider.reasoning_field = nil

---@param opts table
---@return llm.NvidiaProvider
function NvidiaProvider:new(opts)
  local instance = OpenAIProtocol.new(self, opts) --[[@as llm.NvidiaProvider]]
  return setmetatable(instance, self)
end

return NvidiaProvider
