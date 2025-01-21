local M = {}

local SERVERS = require "llm.servers.const"

local default_servers = {
  {

    server = SERVERS.DEEP_SEEK,
    base_url = "https://api.deepseek.com/v1/chat/completions",
    model = "deepseek-chat",
    stream = true,
    multi_round = true,
    user_role = "user",
  },
}

function M.defaults()
  return {
    servers = {},
    default_server = SERVERS.DEEP_SEEK,
    loading_mark = "**Generating response ...**",
    user_prompt = "❯",
    question_hi = { fg = "#1abc9c" },
    base_config_dir = vim.fn.stdpath "cache" .. "/inobit/llm",
    config_dir = "config",
    session_dir = "session",
    config_filename = "config.json",
    chat_win = {
      width_percentage = 0.7,
      response_height_percentage = 0.7,
      input_height_percentage = 0.1,
      winblend = 5,
    },
    session_picker_win = {
      width_percentage = 0.4,
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

local function install_servers(servers)
  servers = servers or {}
  local map = vim.iter(default_servers):fold({}, function(acc, v)
    acc[v.server] = v
    return acc
  end)

  vim.iter(servers):each(function(item)
    map[item.server] = vim.tbl_deep_extend("force", {}, map[item.server] or {}, item)
  end)
  return map
end

function M.install_win_cursor_move_keymap(mappings)
  M.options.win_cursor_move_mappings = mappings
end

function M.get_config_file_path(server_name)
  if server_name then
    return M.options.base_config_dir
      .. "/"
      .. M.options.config_dir
      .. "/"
      .. server_name
      .. "/"
      .. M.options.config_filename
  else
    return nil
  end
end

M.options = {}

function M.setup(options)
  options = options or {}
  M.options = vim.tbl_deep_extend(
    "force",
    { win_cursor_move_mappings = M.options.win_cursor_move_mappings },
    M.defaults(),
    options
  )
  M.options.servers = install_servers(M.options.servers)
end

return M
