local config = require "inobit.llm.config"
local win = require "inobit.llm.win"
local util = require "inobit.llm.util"
local curl = require "plenary.curl"
local notify = require "inobit.llm.notify"

---https://github.com/nvim-lua/plenary.nvim/blob/master/lua/plenary/curl.lua#L201
---@alias llm.server.plenaryCurlArgs
---| "url"
---| "method"
---| "body"
---| "headers"
---| "accept"
---| "in_file"

---@class llm.server.RequestOpts
---@field callback? fun(data: llm.server.Response)
---@field stream? fun(error: string, data: string, self?: Job)
---@field on_error? fun(err: llm.server.Error)
---@field [llm.server.plenaryCurlArgs] any

---@alias llm.server.StopSignal
---| 0    normal
---| 1000 user canceled
---| 1001 new request override
---| 1002 parsing error

---@class llm.server.Error
---@field message string
---@field stderr string
---@field exit number

---@class llm.server.Response
---@field status number
---@field headers string[]
---@field body string
---@field exit number

---@class llm.Server: llm.server.ServerOptions
local Server = {}
Server.__index = Server

---@class llm.ChatServer: llm.Server
local ChatServer = {}
ChatServer.__index = ChatServer
setmetatable(ChatServer, Server)

---now only support OpenAI API(deepseek compatible with openai api)
---@class llm.OpenAIServer: llm.ChatServer
local OpenAIServer = {}
OpenAIServer.__index = OpenAIServer
-- extend Server
setmetatable(OpenAIServer, ChatServer)

---@class llm.TranslateServer: llm.Server
local TranslateServer = {}
TranslateServer.__index = TranslateServer
setmetatable(TranslateServer, Server)

---https://developers.deepl.com/docs/api-reference/translate
---@class llm.server.deepl.text.RequestBody
---@field text string
---@field source_lang? string
---@field target_lang string
---@field context? string
---@field model_type? "latency_optimized" | "quality_optimized" | "prefer_quality_optimized"

---@class llm.server.deepl.text.ResponseBody
---@field data string
---@field alternatives string[]
---@field code number
---@field id number
---@field method string
---@field source_lang string
---@field target_lang string

---@class llm.DeepLServer: llm.TranslateServer
local DeepLServer = {}
DeepLServer.__index = DeepLServer
setmetatable(DeepLServer, TranslateServer)

---@class llm.ServerManager
---@field servers table<string, llm.Server>[]
---@field default_server llm.Server
---@field chat_server llm.Server
---@field translate_server llm.Server
local ServerManager = {}
ServerManager.__index = ServerManager

---@param opts llm.server.ServerOptions
---@return llm.Server
function Server:new(opts)
  local server = vim.tbl_deep_extend("force", {}, opts)
  return setmetatable(server, self)
end

---@param class llm.Server
---@return boolean
function Server:_is_the_class(class)
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
function Server:is_chat_server()
  return self:_is_the_class(ChatServer)
end

---@return boolean
function Server:is_translate_server()
  return self:_is_the_class(TranslateServer)
end

function Server:_check_api_key()
  local api_key_name = self.api_key_name
  local api_key = vim.fn.getenv(api_key_name)
  if not api_key or api_key == vim.NIL then
    vim.ui.input({ prompt = "Enter " .. api_key_name .. ": " }, function(input)
      vim.fn.setenv(api_key_name, input)
    end)
  end
end

---build original curl request,can used for plenary Job:new
---@param body any
---@return string[]
function Server:_build_original_curl_args(body)
  local args = {
    self.base_url,
    "-N",
    "-X",
    "POST",
    "-H",
    "Content-Type: application/json",
    "-H",
    "Authorization: Bearer " .. vim.fn.getenv(self.api_key_name),
    "-d",
    vim.fn.json_encode(body),
  }
  return args
end

---@param body table
---@param curl_args? table<llm.server.plenaryCurlArgs,any>
---@return llm.server.RequestOpts
function Server:build_request_opts(body, curl_args)
  local headers = {
    content_type = "application/json",
    authorization = "Bearer " .. vim.fn.getenv(self.api_key_name),
  }
  return vim.tbl_deep_extend(
    "keep",
    { url = self.base_url, body = vim.fn.json_encode(body), headers = headers },
    curl_args or { method = "POST" }
  )
end

---build curl request,used for plenary curl
---@param input llm.session.Message[]
---@param server_params? llm.server.BaseOptions
---@param curl_args? table<llm.server.plenaryCurlArgs,any>
---@return llm.server.RequestOpts
function OpenAIServer:build_request_opts(input, server_params, curl_args)
  local body = vim.tbl_deep_extend("force", {}, {
    model = self.model,
    messages = input,
    stream = self.stream,
    temperature = self.temperature or 0.6,
  }, server_params or {})
  return Server.build_request_opts(self, body, curl_args)
end

---@param data llm.server.Response
---@return string
function OpenAIServer:parse_translation_result(data)
  local body = vim.json.decode(data.body)
  return body.choices[1].message.content
end

---@param body llm.server.deepl.text.RequestBody
---@param curl_args? table<llm.server.plenaryCurlArgs,any>
---@return llm.server.RequestOpts
function DeepLServer:build_request_opts(body, curl_args)
  return Server.build_request_opts(self, body, curl_args)
end

function DeepLServer:clean_source_text(text)
  return text:gsub("\n+", " ")
end

---@param data llm.server.Response
---@return llm.server.deepl.text.ResponseBody
function DeepLServer:parse_translation_result(data)
  local body = vim.json.decode(data.body, { luanil = { object = true, array = true } })
  return body
end

---send request to server
---@param opts llm.server.RequestOpts
---@return Job | llm.server.Response | nil
function Server:request(opts)
  local auth = vim.fn.getenv(self.api_key_name)
  if not auth or auth == vim.NIL then
    self:_check_api_key()
  else
    if opts.callback then
      opts.callback = vim.schedule_wrap(opts.callback)
    end
    if opts.stream then
      opts.stream = vim.schedule_wrap(opts.stream)
    end
    if opts.on_error then
      ---@type fun(err: llm.server.Error)
      local error_callback = opts.on_error
      opts.on_error = vim.schedule_wrap(
        ---@param error llm.server.Error
        function(error)
          if error.exit == 1000 then
            error.message = "user canceled!"
          elseif error.exit == 1001 then
            error.message = "new request override!"
          end
          error_callback(error)
        end
      )
    end
    local job = curl.request(opts)
    return job
  end
end

function ServerManager:set_default_server()
  local default_server = config.options.default_server
  local default_chat_server = config.options.default_chat_server or config.options.default_server
  local default_translate_server = config.options.default_translate_server or config.options.default_server
  self.default_server = self.servers[default_server]
  self.chat_server = self.servers[default_chat_server]
  self.translate_server = self.servers[default_translate_server]
end

---@param type? ServerType
---@return string[]
function ServerManager:server_selector(type)
  if type == "chat" then
    return vim.tbl_filter(function(v)
      return not self.servers[v].server_type or self.servers[v].server_type == "chat"
    end, vim.tbl_keys(self.servers))
  else
    -- all for translate type
    return vim.tbl_keys(self.servers)
  end
end

---@param type ServerType
---@param callback? fun(server: llm.Server)
function ServerManager:open_selector(type, callback)
  win.PickerWin:new {
    title = string.format("select %s server", type),
    data_filter_wraper = function()
      local data = self:server_selector(type)
      table.sort(data)
      return function(input)
        return util.data_filter(input, data)
      end
    end,
    winOptions = config.options.server_picker_win,
    enter_handler = function(selected)
      if type == "chat" then
        self.chat_server = self.servers[selected]
        notify.info(string.format("selected chat server: %s, does not affect existing sessions!", selected))
        if callback then
          callback(self.chat_server)
        end
      elseif type == "translate" then
        self.translate_server = self.servers[selected]
        notify.info(string.format("selected translate server: %s", selected))
        if callback then
          callback(self.translate_server)
        end
      end
    end,
  }
end

---@return llm.ServerManager
function ServerManager:init()
  local servers = vim.tbl_deep_extend("force", {}, config.options.servers) --[=[@as table<string, llm.server.ServerOptions>]=]
  for key, value in pairs(servers) do
    if not value.server_type or value.server_type == "chat" then
      --TODO: support more llm server
      servers[key] = OpenAIServer:new(value)
    elseif value.server_type == "translate" then
      -- deepL deepLX
      if value.server:lower():find "deepl" then
        servers[key] = DeepLServer:new(value)
      else
        servers[key] = TranslateServer:new(value)
      end
    else
      servers[key] = Server:new(value)
    end
  end
  self.servers = servers --[=[@as table<string, llm.Server>[]]=]
  self:set_default_server()
  return self
end

return ServerManager:init()
