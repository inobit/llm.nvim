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
---@field provider_configs table<string, llm.config.ProviderEntry> provider configurations (not instances)
---@field resolved_providers table<string, llm.Provider> cache of resolved provider instances
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
  -- Extract all BaseOptions fields from provider instance
  local base_opts = {}
  for _, field in ipairs(config.BASE_OPTIONS_FIELDS) do
    if self[field] ~= nil then
      base_opts[field] = self[field]
    end
  end

  local body = vim.tbl_deep_extend("force", {}, {
    model = self.model,
    messages = input,
  }, base_opts, provider_params or {})
  local opts = Provider.build_request_opts(self, body)
  -- Chat providers: base_url goes to /v1, append /chat/completions
  opts.url = self.base_url .. "/chat/completions"
  return opts
end

---@param input llm.session.Message[]
---@param provider_params? llm.provider.BaseOptions
---@return llm.provider.RequestOpts
function OpenRouterProvider:build_request_opts(input, provider_params)
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

---Get the default model for a provider based on usage type.
---@param provider_name string The provider name
---@param provider_type? ProviderType The type of provider ("chat" or "translate")
---@return string model_id The default model ID for this provider
function ProviderManager:_get_provider_default_model(provider_name, provider_type)
  local provider_config = config.providers[provider_name]
  if not provider_config then
    error("Unknown provider: " .. provider_name)
  end

  -- Priority: specific type default → general default_model
  local model_id
  if provider_type == "chat" then
    model_id = provider_config.default_chat_model or provider_config.default_model
  elseif provider_type == "translate" then
    model_id = provider_config.default_translate_model or provider_config.default_model
  else
    model_id = provider_config.default_model
  end

  if not model_id then
    error("Provider " .. provider_name .. " has no default_model configured")
  end
  return model_id
end

---Set default providers by looking up default_model from each provider's config.
function ProviderManager:set_default_provider()
  local default_provider = config.options.default_provider
  local default_chat_provider = config.options.default_chat_provider or config.options.default_provider
  local default_translate_provider = config.options.default_translate_provider or config.options.default_provider

  -- Resolve default_provider (general, no type)
  local model_id = self:_get_provider_default_model(default_provider, nil)
  self.default_provider = self:resolve_provider(default_provider, model_id)

  -- Resolve chat_provider (uses default_chat_model with fallback to default_model)
  model_id = self:_get_provider_default_model(default_chat_provider, "chat")
  self.chat_provider = self:resolve_provider(default_chat_provider, model_id)

  -- Resolve translate_provider (uses default_translate_model with fallback to default_model)
  model_id = self:_get_provider_default_model(default_translate_provider, "translate")
  self.translate_provider = self:resolve_provider(default_translate_provider, model_id)
end

---@param type? ProviderType
---@return string[]
function ProviderManager:provider_selector(type)
  if type == "chat" then
    return vim.tbl_filter(function(v)
      return self.provider_configs[v].provider_type == "chat"
    end, vim.tbl_keys(self.provider_configs))
  else
    -- all for translate type
    return vim.tbl_keys(self.provider_configs)
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
      local provider_config = self.provider_configs[selected]
      local model_id = provider_config.default_model
      if not model_id then
        notify.error("Provider " .. selected .. " has no default_model configured")
        return
      end
      local provider = self:resolve_provider(selected, model_id)
      if type == "chat" then
        self.chat_provider = provider
        notify.info(
          string.format("selected chat provider: %s@%s, does not affect existing sessions!", selected, model_id)
        )
        if callback then
          callback(self.chat_provider)
        end
      elseif type == "translate" then
        self.translate_provider = provider
        notify.info(string.format("selected translate provider: %s@%s", selected, model_id))
        if callback then
          callback(self.translate_provider)
        end
      end
    end,
  }
end

---Resolve a provider with model-specific overrides applied.
---Results are cached in resolved_providers table.
---@param provider_name string The provider name (e.g., "OpenRouter")
---@param model_id string The model ID to use
---@return llm.Provider The resolved provider instance
function ProviderManager:resolve_provider(provider_name, model_id)
  local cache_key = provider_name .. "@" .. model_id

  -- Return cached instance if available (use rawget to avoid __index recursion)
  local cached = rawget(self.resolved_providers, cache_key)
  if cached then
    return cached
  end

  -- Get the provider entry from config
  local provider_entry = config.providers[provider_name]
  if not provider_entry then
    error("Unknown provider: " .. provider_name)
  end

  -- Merge order: type-specific defaults -> provider_entry -> model_overrides
  -- Select defaults based on provider_type (required field)
  local defaults = provider_entry.provider_type == "translate" and (config.options.translate_provider_defaults or {})
    or config.options.chat_provider_defaults

  -- 1. Start with type-specific defaults
  local resolved_config = vim.tbl_deep_extend("force", {}, defaults)

  -- 2. Merge with provider-specific config
  resolved_config = vim.tbl_deep_extend("force", resolved_config, provider_entry)

  -- 3. Apply model-specific overrides if they exist
  local model_overrides = config.normalize_model_overrides(provider_entry.model_overrides)
  if model_overrides[model_id] then
    resolved_config = vim.tbl_deep_extend("force", resolved_config, model_overrides[model_id])
  end

  -- Set the model and provider name
  resolved_config.model = model_id
  resolved_config.provider = provider_name

  -- Remove fields not needed for provider instances
  resolved_config.fetch_models = nil
  resolved_config.cache_ttl = nil
  resolved_config.model_overrides = nil
  resolved_config.default_model = nil
  resolved_config.default_chat_model = nil
  resolved_config.default_translate_model = nil

  -- Create the appropriate provider instance based on type (required field)
  local instance
  if resolved_config.provider_type == "chat" then
    if resolved_config.provider == "OpenRouter" then
      instance = OpenRouterProvider:new(resolved_config)
    else
      instance = OpenAIProvider:new(resolved_config)
    end
  elseif resolved_config.provider_type == "translate" then
    if resolved_config.provider:lower():find "deepl" then
      instance = DeepLProvider:new(resolved_config)
    else
      instance = TranslateProvider:new(resolved_config)
    end
  end

  -- Cache and return the instance
  self.resolved_providers[cache_key] = instance
  return instance
end

---@return llm.ProviderManager
function ProviderManager:init()
  self.provider_configs = config.providers --[[@as table<string, llm.config.ProviderEntry>]]
  -- Set up metatable for auto-resolving on access
  local manager = self
  self.resolved_providers = setmetatable({}, {
    __index = function(_, key)
      -- Parse "Provider@Model" format
      local provider_name, model_id = key:match "^([^@]+)@(.+)$"
      if provider_name and model_id then
        return manager:resolve_provider(provider_name, model_id)
      end
      return nil
    end,
  })
  self:set_default_provider()
  return self
end

return ProviderManager:init()
