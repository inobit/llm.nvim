local config = require "inobit.llm.config"
local win = require "inobit.llm.win"
local util = require "inobit.llm.util"
local notify = require "inobit.llm.notify"

---@class llm.RequestJob
---@field _job vim.SystemObj
---@field kill fun(self: llm.RequestJob, signal?: number, reason?: string)
---@field is_active fun(self: llm.RequestJob): boolean
---@field pid number?

---@class llm.provider.RequestOpts
---@field callback? fun(data: llm.provider.Response)
---@field stream? fun(error: string, data: string)
---@field on_error? fun(err: llm.provider.Error)
---@field url string
---@field method? string
---@field body? string
---@field headers? table<string, string>

---@class llm.provider.Error
---@field message string
---@field stderr string

---@class llm.provider.Response
---@field status number
---@field headers string[]
---@field body string

---@class llm.Provider: llm.provider.ProviderOptions
local Provider = {}
Provider.__index = Provider

---@class llm.ChatProvider: llm.Provider
local ChatProvider = {}
ChatProvider.__index = ChatProvider
setmetatable(ChatProvider, Provider)

---now only support OpenAI API(deepseek compatible with openai api)
---@class llm.OpenAIProvider: llm.ChatProvider
local OpenAIProvider = {}
OpenAIProvider.__index = OpenAIProvider
-- extend Provider
setmetatable(OpenAIProvider, ChatProvider)

---@class llm.OpenRouterProvider: llm.OpenAIProvider
local OpenRouterProvider = {}
OpenRouterProvider.__index = OpenRouterProvider
setmetatable(OpenRouterProvider, OpenAIProvider)

---@class llm.TranslateProvider: llm.Provider
local TranslateProvider = {}
TranslateProvider.__index = TranslateProvider
setmetatable(TranslateProvider, Provider)

---https://developers.deepl.com/docs/api-reference/translate
---@class llm.provider.deepl.text.RequestBody
---@field text string
---@field source_lang? string
---@field target_lang string
---@field context? string
---@field model_type? "latency_optimized" | "quality_optimized" | "prefer_quality_optimized"

---@class llm.provider.deepl.text.ResponseBody
---@field data string
---@field alternatives string[]
---@field code number
---@field id number
---@field method string
---@field source_lang string
---@field target_lang string

---@class llm.DeepLProvider: llm.TranslateProvider
local DeepLProvider = {}
DeepLProvider.__index = DeepLProvider
setmetatable(DeepLProvider, TranslateProvider)

---@class llm.ProviderManager
---@field providers table<string, llm.Provider>[]
---@field default_provider llm.Provider
---@field chat_provider llm.Provider
---@field translate_provider llm.Provider
local ProviderManager = {}
ProviderManager.__index = ProviderManager

---@param opts llm.provider.ProviderOptions
---@return llm.Provider
function Provider:new(opts)
  local provider = vim.tbl_deep_extend("force", {}, opts)
  return setmetatable(provider, self)
end

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

---@return boolean
function Provider:is_chat_provider()
  return self:_is_the_class(ChatProvider)
end

---@return boolean
function Provider:is_translate_provider()
  return self:_is_the_class(TranslateProvider)
end

function Provider:_check_api_key()
  local api_key_name = self.api_key_name
  local api_key = vim.fn.getenv(api_key_name)
  if not api_key or api_key == vim.NIL then
    vim.ui.input({ prompt = "Enter " .. api_key_name .. ": " }, function(input)
      vim.fn.setenv(api_key_name, input)
    end)
  end
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

---send request to provider
---@param opts llm.provider.RequestOpts
---@return llm.RequestJob | nil
function Provider:request(opts)
  local auth = vim.fn.getenv(self.api_key_name)
  if not auth or auth == vim.NIL then
    self:_check_api_key()
    return nil
  end

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
    -- Normal exit: code=0, signal=0; Killed by signal: code=0, signal=signal_value
    if obj.code ~= 0 or obj.signal ~= 0 then
      if error_callback then
        error_callback {
          message = wrapper.reason or table.concat(stderr_data, ""),
          stderr = table.concat(stderr_data, ""),
        }
      end
    elseif exit_callback then
      exit_callback {
        status = 200,
        headers = {},
        body = obj.stdout or "",
      }
    end
  end)

  wrapper._job = job
  wrapper.pid = job.pid
  wrapper.reason = nil
  function wrapper:kill(sig, reason)
    self.reason = reason
    self._job:kill(sig or 9)
  end
  function wrapper:is_active()
    return self._job.pid ~= nil
  end

  return wrapper
end

---@param body table
---@return llm.provider.RequestOpts
function Provider:build_request_opts(body)
  ---@type string?
  local auth = vim.fn.getenv(self.api_key_name)
  if not auth or auth == vim.NIL then
    auth = ""
  end
  local headers = {
    content_type = "application/json",
    authorization = "Bearer " .. auth,
  }
  return {
    url = self.base_url,
    body = vim.fn.json_encode(body),
    headers = headers,
    method = "POST",
  }
end

---@return string
function Provider:get_reasoning_content_key()
  return "reasoning_content"
end

---@param input llm.session.Message[]
---@param provider_params? llm.provider.BaseOptions
---@return llm.provider.RequestOpts
function OpenAIProvider:build_request_opts(input, provider_params)
  local body = vim.tbl_deep_extend("force", {}, {
    model = self.model,
    messages = input,
    stream = self.stream,
    temperature = self.temperature or 0.6,
    max_tokens = self.max_tokens or 4096,
  }, provider_params or {})
  return Provider.build_request_opts(self, body)
end

---@param input llm.session.Message[]
---@param provider_params? llm.provider.BaseOptions
---@return llm.provider.RequestOpts
function OpenRouterProvider:build_request_opts(input, provider_params)
  provider_params = provider_params or {}
  local reasoning =
    vim.tbl_deep_extend("force", vim.empty_dict(), self.reasoning or {}, provider_params.reasoning or {})
  provider_params.reasoning = reasoning
  return OpenAIProvider.build_request_opts(self, input, provider_params)
end

---@return string
function OpenRouterProvider:get_reasoning_content_key()
  return "reasoning"
end

---@param data llm.provider.Response
---@return string?
function OpenAIProvider:parse_translation_result(data)
  local body = vim.json.decode(data.body)
  local content = vim.tbl_get(body, "choices", 1, "message", "content")
  if content then
    if content:sub(-1) == "\n" then
      content = content:sub(1, -2)
    end
    return content
  else
    notify.error(string.format("no translation result found: %s", vim.json.encode(data.body)))
  end
end

---@param data llm.provider.Response
---@return string?
function OpenAIProvider:parse_direct_result(data)
  local body = vim.json.decode(data.body)
  local content = vim.tbl_get(body, "choices", 1, "message", "content")
  if content then
    return content:gsub("%s+$", "")
  end
  return nil
end

---@param data llm.provider.Response
---@return string?
function OpenRouterProvider:parse_direct_result(data)
  return OpenAIProvider.parse_direct_result(self, data)
end

---@param body llm.provider.deepl.text.RequestBody
---@return llm.provider.RequestOpts
function DeepLProvider:build_request_opts(body)
  return Provider.build_request_opts(self, body)
end

function DeepLProvider:clean_source_text(text)
  return text:gsub("\n+", " ")
end

---@param data llm.provider.Response
---@return llm.provider.deepl.text.ResponseBody
function DeepLProvider:parse_translation_result(data)
  local body = vim.json.decode(data.body, { luanil = { object = true, array = true } })
  return body
end

---handle stream chunk, common mode(openai mode)
---@param response string
---@param chat llm.Chat
---@return llm.session.Message | string | nil
function Provider:handle_stream_chunk(response, chat)
  local chunk = response:match "^data:%s(.+)$"
  if chunk == nil or chunk == "[DONE]" then
    return chunk
  end
  -- trying to parse chunk
  local status = false
  status, chunk = pcall(vim.json.decode, chunk)
  if not status then
    return string.format("parse error: %s", response)
  end
  if chunk.choices and chunk.choices ~= vim.NIL and chunk.choices[1] and chunk.choices[1].delta then
    local delta = chunk.choices[1].delta
    local think_tag = chat.think_tag

    -- match think tag in first response
    if not chat.no_first_res_in_turn then
      if util.empty_str(delta.content) then
        return "[IGNORE]" -- just ignore
      end
      if delta.content:match "^<think>" then
        think_tag.is = true
      end
    end

    local reasoning_content_key = self:get_reasoning_content_key()
    local message = {}
    if util.empty_str(delta.role, false) then
      message.role = nil
    else
      message.role = delta.role
    end

    -- handle response with think tag
    if think_tag.is then
      if not chat.no_first_res_in_turn then
        -- remove think begin tag
        message.reasoning_content = delta.content:gsub("^<think>", "")
      else
        -- handle first </think> tag
        if not think_tag.end_think and not util.empty_str(delta.content) and delta.content:match "</think>" then
          -- example: xxx</think>yyy
          message.reasoning_content = delta.content:match "(.*)</think>" -- get xxx
          think_tag.payload = delta.content:match "</think>(.*)" -- save yyy
          think_tag.end_think = true
        else
          -- handle think content
          if not think_tag.end_think then
            message.reasoning_content = delta.content
          else
            if think_tag.payload then -- concat yyy
              if util.empty_str(delta.content, false) then
                delta.content = ""
              end
              message.content = think_tag.payload .. delta.content
              think_tag.payload = nil
            else
              message.content = delta.content
            end
          end
        end
      end
    -- hanlde response without think tag
    else
      message.reasoning_content = delta[reasoning_content_key]
      message.content = delta.content
    end

    if util.empty_str(message.reasoning_content, false) then
      message.reasoning_content = nil
    else
      message.reasoning_content = message.reasoning_content:gsub("\n\n", "\n")
    end

    if util.empty_str(message.content, false) then
      message.content = ""
    else
      message.content = message.content:gsub("\n\n", "\n")
    end

    chat.no_first_res_in_turn = true

    return message
  elseif chunk.usage then
    -- Some APIs send a final chunk with usage info but empty choices
    return "[IGNORE]"
  else
    return string.format("parse error: %s", vim.inspect(chunk))
  end
end

function ProviderManager:set_default_provider()
  local default_provider = config.options.default_provider
  local default_chat_provider = config.options.default_chat_provider or config.options.default_provider
  local default_translate_provider = config.options.default_translate_provider or config.options.default_provider
  self.default_provider = self.providers[default_provider]
  self.chat_provider = self.providers[default_chat_provider]
  self.translate_provider = self.providers[default_translate_provider]
end

---@param type? ProviderType
---@return string[]
function ProviderManager:provider_selector(type)
  if type == "chat" then
    return vim.tbl_filter(function(v)
      return not self.providers[v].provider_type or self.providers[v].provider_type == "chat"
    end, vim.tbl_keys(self.providers))
  else
    -- all for translate type
    return vim.tbl_keys(self.providers)
  end
end

---@param type ProviderType
---@param callback? fun(provider: llm.Provider)
function ProviderManager:open_provider_selector(type, callback)
  win.PickerWin:new {
    title = string.format("select %s provider", type),
    data_filter_wraper = function()
      local data = self:provider_selector(type)
      table.sort(data)
      return function(input)
        return util.data_filter(input, data)
      end
    end,
    winOptions = config.options.provider_picker_win,
    enter_handler = function(selected)
      if type == "chat" then
        self.chat_provider = self.providers[selected]
        notify.info(string.format("selected chat provider: %s, does not affect existing sessions!", selected))
        if callback then
          callback(self.chat_provider)
        end
      elseif type == "translate" then
        self.translate_provider = self.providers[selected]
        notify.info(string.format("selected translate provider: %s", selected))
        if callback then
          callback(self.translate_provider)
        end
      end
    end,
  }
end

---@return llm.ProviderManager
function ProviderManager:init()
  local providers = vim.tbl_deep_extend("force", {}, config.options.providers) --[=[@as table<string, llm.provider.ProviderOptions>]=]
  for key, value in pairs(providers) do
    if not value.provider_type or value.provider_type == "chat" then
      --TODO: support more llm provider
      if value.provider == "OpenRouter" then
        providers[key] = OpenRouterProvider:new(value)
      else
        providers[key] = OpenAIProvider:new(value)
      end
    elseif value.provider_type == "translate" then
      -- deepL deepLX
      if value.provider:lower():find "deepl" then
        providers[key] = DeepLProvider:new(value)
      else
        providers[key] = TranslateProvider:new(value)
      end
    else
      providers[key] = Provider:new(value)
    end
  end
  self.providers = providers --[=[@as table<string, llm.Provider>[]]=]
  self:set_default_provider()
  return self
end

return ProviderManager:init()
