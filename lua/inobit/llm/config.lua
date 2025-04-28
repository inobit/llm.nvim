local M = {}

local Path = require "plenary.path"

---@alias ServerType "chat" | "translate"

---@class llm.server.BaseOptions
---@field stream? boolean
---@field multi_round? boolean
---@field user_role? string
---@field temperature? number
---@field max_tokens? number

---@class llm.server.CommonOptions: llm.server.BaseOptions
---@field base_url string
---@field api_key_name string
---@field server_type? ServerType

---@class llm.server.ServerOptions: llm.server.CommonOptions
---@field server string
---@field model string

---@class llm.server.Model: llm.server.CommonOptions
---@field model string
---@field base_url? string
---@field api_key_name? string

---@class llm.config.ServerOptions: llm.server.CommonOptions
---@field server string
---@field models (string | llm.server.Model)[]

---@class llm.WinOptions
---@field width_percentage number
---@field input_height? integer
---@field input_height_percentage? number
---@field content_height_percentage number
---@field winblend integer

---@class llm.Config
---@field servers table<string, llm.server.ServerOptions>
---@field default_server string
---@field default_chat_server? string
---@field default_translate_server? string
---@field loading_mark string
---@field user_prompt string
---@field question_hi string | vim.api.keyset.highlight
---@field data_dir string
---@field session_dir string
---@field config_filename string
---@field chat_win llm.WinOptions
---@field session_picker_win llm.WinOptions
---@field server_picker_win llm.WinOptions

---@return llm.config.ServerOptions[]
local function default_servers()
  return {
    {
      server = "DeepSeek",
      server_type = "chat",
      base_url = "https://api.deepseek.com/v1/chat/completions",
      api_key_name = "DEEPSEEK_API_KEY",
      stream = true,
      multi_round = true,
      temperature = 0.6,
      max_tokens = 4096,
      user_role = "user",
      models = { "deepseek-chat", "deepseek-reasoner" },
    },
    {
      server = "SiliconFlow",
      server_type = "chat",
      base_url = "https://api.siliconflow.cn/v1/chat/completions",
      api_key_name = "SILICONFLOW_API_KEY",
      stream = true,
      multi_round = true,
      temperature = 0.6,
      max_tokens = 4096,
      user_role = "user",
      models = { "deepseek-ai/DeepSeek-V3", "deepseek-ai/DeepSeek-R1" },
    },
  }
end

function M.defaults()
  return {
    -- server@model
    default_server = "SiliconFlow@deepseek-ai/DeepSeek-V3",
    loading_mark = "**Generating response ...**",
    user_prompt = "❯",
    question_hi = { fg = "#1abc9c" },
    data_dir = vim.fn.stdpath "cache" .. "/inobit/llm",
    session_dir = "session",
    chat_win = {
      width_percentage = 0.7,
      content_height_percentage = 0.7,
      input_height_percentage = 0.1,
      winblend = 3,
    },
    session_picker_win = {
      width_percentage = 0.5,
      input_height = 1,
      content_height_percentage = 0.3,
      winblend = 5,
    },
    server_picker_win = {
      width_percentage = 0.3,
      input_height = 1,
      content_height_percentage = 0.2,
      winblend = 5,
    },
  }
end

---@param servers llm.config.ServerOptions[]
---@return llm.server.ServerOptions[]
local function flat_servers(servers)
  return vim
    .iter(servers)
    :map(function(item)
      local models = item.models
      --WARNING: change object
      item.models = nil
      return vim
        .iter(models)
        :map(function(model)
          if type(model) == "string" then
            model = { model = model }
          end
          return vim.tbl_deep_extend("force", {}, item, model)
        end)
        :totable()
    end)
    :flatten()
    :totable()
end

---@param servers llm.config.ServerOptions[]
---@return table<string, llm.server.ServerOptions>
local function install_servers(servers)
  servers = servers or {}

  local default_servers_flat = flat_servers(default_servers())
  local map = vim.iter(default_servers_flat):fold({}, function(acc, v)
    acc[v.server .. "@" .. v.model] = v
    return acc
  end)
  if not vim.tbl_isempty(servers) then
    servers = flat_servers(servers)
    vim.iter(servers):each(function(item)
      map[item.server .. "@" .. item.model] =
        vim.tbl_deep_extend("force", {}, map[item.server .. "@" .. item.model] or {}, item)
    end)
  end
  return map
end

---@return string
function M.get_session_dir()
  return Path:new(M.options.data_dir, M.options.session_dir).filename
end

---@class llm.SetupOptions
---@field servers? llm.config.ServerOptions[]
---@field default_server? string
---@field default_chat_server? string
---@field default_translate_server? string
---@field loading_mark? string
---@field user_prompt? string
---@field question_hi? string | vim.api.keyset.highlight group name or options
---@field thinking_hi? string | vim.api.keyset.highlight group name or options
---@field data_dir? string
---@field session_dir? string
---@field config_filename? string
---@field chat_win? llm.WinOptions
---@field session_picker_win? llm.WinOptions
---@field server_picker_win? llm.WinOptions

---@param options? llm.SetupOptions
function M.setup(options)
  --TODO: check options,api_key_name
  options = options or {}
  local combined = vim.tbl_deep_extend("force", {}, M.defaults(), options)
  combined.servers = install_servers(combined.servers)
  M.options = combined --[[@as llm.Config]]
end

return M
