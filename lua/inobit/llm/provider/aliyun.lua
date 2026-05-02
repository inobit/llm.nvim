-- Aliyun DashScope Provider
-- Extends OpenAIProtocol for Aliyun's DashScope API compatibility

local OpenAIProtocol = require "inobit.llm.provider.openai_protocol"

---@class llm.OpenAIProtocol : llm.Provider

---@class llm.AliyunProvider: llm.OpenAIProtocol
local AliyunProvider = {}
AliyunProvider.__index = AliyunProvider
setmetatable(AliyunProvider, { __index = OpenAIProtocol })

-- Aliyun uses standard OpenAI response format
AliyunProvider.reasoning_field = nil

---@param opts table
---@return llm.AliyunProvider
function AliyunProvider:new(opts)
  local instance = OpenAIProtocol.new(self, opts) --[[@as llm.AliyunProvider]]
  return setmetatable(instance, self)
end

return AliyunProvider
