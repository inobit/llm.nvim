local config = require "inobit.llm.config"
local win = require "inobit.llm.win"
local util = require "inobit.llm.util"
local curl = require "plenary.curl"
local notify = require "inobit.llm.notify"

---@alias ServiceType "chat" | "translate"

---https://github.com/nvim-lua/plenary.nvim/blob/master/lua/plenary/curl.lua#L201
---@alias llm.server.plenaryCurlArgs
---| "url"
---| "method"
---| "body"
---| "headers"
---| "accept"
---| "in_file"

---@alias llm.server.StopSignal
---| 0    normal
---| 1000 user canceled
---| 1001 new request override
---| 1002 parsing error

---@class llm.server.Error
---@field message string
---@field stderr string
---@field exit number

---@class llm.server.Request
---@field url string
---@field method string
---@field body? string
---@field headers? table<string, string>
---@field callback? fun(data: llm.server.Response)
---@field stream? fun(error: string, data: string, self?: Job)
---@field on_error? fun(err: llm.server.Error)
---@field [llm.server.plenaryCurlArgs] any

---@class llm.server.Response
---@field status number
---@field headers string[]
---@field body string
---@field exit number

---@class llm.Server: llm.server.ServerOptions
local Server = {}
Server.__index = Server

---now only support OpenAI API(deepseek compatible with openai api)
---@class llm.OpenAIServer: llm.Server
local OpenAIServer = {}
OpenAIServer.__index = OpenAIServer
-- extend Server
setmetatable(OpenAIServer, Server)

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
  return setmetatable(server, Server)
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
---@param input llm.session.Message[]
---@param params? llm.server.BaseOptions
---@return string[]
function Server:_build_original_curl_args(input, params)
  params = vim.tbl_deep_extend("force", {}, {
    model = self.model,
    messages = input,
    stream = self.stream,
    temperature = self.temperature or 0.6,
  }, params or {})

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
    vim.fn.json_encode(params),
  }
  return args
end

---build curl request,used for plenary curl
---@param input llm.session.Message[]
---@param server_params? llm.server.BaseOptions
---@param curl_args? table<llm.server.plenaryCurlArgs,any>
---@return llm.server.Request
function Server:_build_curl_opts(input, server_params, curl_args)
  local body = vim.tbl_deep_extend("force", {}, {
    model = self.model,
    messages = input,
    stream = self.stream,
    temperature = self.temperature or 0.6,
  }, server_params or {})
  local headers = {
    content_type = "application/json",
    authorization = "Bearer " .. vim.fn.getenv(self.api_key_name),
  }
  return vim.tbl_deep_extend(
    "keep",
    { url = self.base_url, body = vim.fn.json_encode(body), headers = headers },
    curl_args or {}
  )
end

---send request to server
---@param input llm.session.Message[]
---@param server_params? llm.server.BaseOptions override default options
---@param curl_args? table<llm.server.plenaryCurlArgs, any>
---@param exit_callback? fun(data: llm.server.Response)
---@param stream_callback? fun(error: string, data: string, self?: Job)
---@param error_callback? fun(err: llm.server.Error)
---@return Job | llm.server.Response | nil
function Server:request(input, server_params, curl_args, exit_callback, stream_callback, error_callback)
  local auth = vim.fn.getenv(self.api_key_name)
  if not auth or auth == vim.NIL then
    self:_check_api_key()
  else
    curl_args = curl_args or {}
    -- default method "POST"
    if not curl_args.method then
      curl_args.method = "POST"
    end
    local opts = self:_build_curl_opts(input, server_params, curl_args)
    if exit_callback then
      opts.callback = vim.schedule_wrap(exit_callback)
    end
    if stream_callback then
      opts.stream = vim.schedule_wrap(stream_callback)
    end
    if error_callback then
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

---@return string[]
function ServerManager:server_selector()
  return vim.tbl_keys(self.servers)
end

---@param type ServiceType
---@param callback? fun(server: llm.Server)
function ServerManager:open_selector(type, callback)
  win.PickerWin:new {
    title = string.format("select %s server", type),
    data_filter_wraper = function()
      local data = self:server_selector()
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
    -- TODO: check server type, maybe support more
    servers[key] = OpenAIServer:new(value)
  end
  self.servers = servers --[=[@as table<string, llm.OpenAIServer>[]]=]
  self:set_default_server()
  return self
end

return ServerManager:init()
