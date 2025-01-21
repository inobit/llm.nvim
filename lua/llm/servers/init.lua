local M = {}

local log = require "llm.log"
local io = require "llm.io"
local util = require "llm.util"
local notify = require "llm.notify"
local SERVERS = require "llm.servers.const"
local config = require "llm.config"
local win = require "llm.win"

-- need set up after config.setup()
local server_selected = config.options.default_server

local function update_auth(server_name, key)
  config.options.servers[server_name].api_key = key
  local _, err =
    io.write_json(config.get_config_file_path(server_name), { api_key = key })
  if err then
    log.error(err)
  end
end

local function input_api_key(server_name)
  local key = nil
  vim.ui.input(
    { prompt = "Enter your " .. server_name .. " API Key: " },
    function(input)
      key = input and tostring(input)
    end
  )
  if not util.empty_str(key) then
    return key
  end
end

local function load_api_key(path)
  local json, err = io.read_json(path)
  if err then
    return nil, err
  else
    return json and json.api_key, nil
  end
end

local function check_common_options(server_name)
  local check = true
  if not config.options.servers[server_name].base_url then
    notify.error "A server URL is required!"
    check = false
  end
  return check
end

local function check_api_key(server_name)
  local api_key = config.options.servers[server_name].api_key
  local path = config.get_config_file_path(server_name)
  local check = true
  if not api_key then
    api_key, _ = load_api_key(path)
    if not api_key then
      api_key = input_api_key(server_name)
      if not api_key then
        notify.error "A valid key is required!"
        check = false
      else
        update_auth(server_name, api_key)
      end
    else
      config.options.servers[server_name].api_key = api_key
    end
  end
  return check
end

local function build_deepseek_request(input)
  local server_name = SERVERS.DEEP_SEEK
  local args = {
    config.options.servers[server_name].base_url,
    "-N",
    "-X",
    "POST",
    "-H",
    "Content-Type: application/json",
    "-H",
    "Authorization: Bearer " .. config.options.servers[server_name].api_key,
    "-d",
    vim.json.encode {
      model = config.options.servers[server_name].model,
      messages = input,
      stream = config.options.servers[server_name].stream,
    },
  }
  return args
end

-- TODO: add more check
local function check_deepseek_options()
  config.options.servers[SERVERS.DEEP_SEEK].build_request =
    build_deepseek_request
  return true
end

function M.check_options(server_name)
  local check = true
  if not check_common_options(server_name) then
    check = false
  end
  if server_name == SERVERS.DEEP_SEEK then
    if not check_deepseek_options() then
      check = false
    end
  end
  if not check_api_key(server_name) then
    check = false
  end
  return check
end

function M.get_server_selected()
  return config.options.servers[server_selected]
end

function M.set_server_selected(server_name)
  if not util.empty_str(server_name) then
    server_selected = server_name
    notify.info("Server is " .. server_name)
  else
    notify.info "Server not changed."
  end
end

function M.get_auth()
  return config.options.servers[server_selected].api_key
end

function M.input_auth(server_name)
  local key = input_api_key(server_name)
  if key then
    update_auth(server_name, key)
  else
    notify.warn "Invalid input! The key is not updated!"
  end
end

local function load_servers()
  return vim.tbl_keys(config.options.servers)
end

local function data_filter(input, data)
  if data then
    return vim.tbl_filter(function(server)
      return server:find(input)
    end, data)
  end
end

local function clear_server_picker_win()
  M.input_buf = nil
  M.input_win = nil
  M.content_buf = nil
  M.content_win = nil
  M.selected_line = nil
end

function M.create_server_picker_win(enter_callback, close_callback)
  local server_win = config.options.server_picker_win
  local input_buf, input_win, content_buf, content_win, selected_line = win.create_select_picker(
    server_win.width_percentage,
    server_win.input_height,
    server_win.content_height_percentage,
    server_win.winblend,
    "servers",
    -- data_filter_wraper, delay load data
    function()
      local data = load_servers() or {}
      return function(input)
        return data_filter(input, data)
      end
    end,
    -- enter handler
    function(line, input_win, content_win)
      if line then
        if vim.api.nvim_win_is_valid(input_win) then
          vim.api.nvim_win_close(input_win, true)
        end
        if vim.api.nvim_buf_is_valid(content_win) then
          vim.api.nvim_win_close(content_win, true)
        end
        if line ~= server_selected then
          M.set_server_selected(line)
          if enter_callback then
            enter_callback()
          end
        end
      end
    end,
    -- close_callback
    function()
      clear_server_picker_win()
      if close_callback then
        close_callback()
      end
    end
  )

  M.input_buf = input_buf
  M.input_win = input_win
  M.content_buf = content_buf
  M.content_win = content_win
  M.selected_line = selected_line

  return input_buf, input_win, content_buf, content_win, selected_line
end

return M
