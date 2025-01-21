local M = {}

local util = require "llm.util"
local servers = require "llm.servers"
local notify = require "llm.notify"
local config = require "llm.config"
local win = require "llm.win"
local io = require "llm.io"
local hl = require "llm.highlights"

local session_name = nil
-- current seesion
local session = {}
-- response field
local response_last_points = {}

function M.get_session()
  return session
end

function M.record_start_point(bufnr)
  response_last_points.start_row, response_last_points.start_col = util.get_last_char_position(bufnr)
end

function M.record_end_point(bufnr)
  response_last_points.end_row, response_last_points.end_col = util.get_last_char_position(bufnr)
end

function M.write_request_to_session(message)
  table.insert(session, message)
end

function M.write_response_to_session(server_role, bufnr)
  M.record_end_point(bufnr)
  local response_last = {
    role = server_role or servers.get_server_selected().server,
    content = table.concat(
      vim.api.nvim_buf_get_text(
        bufnr,
        response_last_points.start_row,
        response_last_points.start_col,
        response_last_points.end_row,
        response_last_points.end_col,
        {}
      ),
      "\n"
    ),
  }
  table.insert(session, response_last)
  response_last = {}
  response_last_points = {}
end

function M.get_session_file_path(server, name)
  if server and name then
    return config.options.base_config_dir
      .. "/"
      .. config.options.session_dir
      .. "/"
      .. server
      .. "/"
      .. name
      .. ".json"
  else
    return nil
  end
end

function M.clear_session(save)
  if save then
    M.save_session()
  end
  session = {}
  session_name = nil
  response_last_points = {}
end

local function auto_generate_session_name(s)
  local LEN = 15
  local RANDOM_LEN = 5
  local m = 0
  local result = ""
  for _, item in ipairs(s) do
    if item.content then
      for i = 0, vim.fn.strchars(item.content) - 1 do
        local char = vim.fn.strcharpart(item.content, i, 1)
        if util.is_legal_char(char) then
          result = result .. char
          m = m + 1
          if m == LEN then
            return result .. "-" .. util.generate_random_string(RANDOM_LEN)
          end
        end
      end
    end
  end
  return result .. "-" .. util.generate_random_string(RANDOM_LEN)
end

local function check_session_name_char(name)
  for i = 0, vim.fn.strchars(name) - 1 do
    local char = vim.fn.strcharpart(name, i, 1)
    if not util.is_legal_char(char) then
      return false, "Contains illegal char"
    end
  end
  return true, nil
end

local function check_session_name_not_exists(name)
  if io.file_is_exist(M.get_session_file_path(servers.get_server_selected().server, name)) then
    return false, "Session name exists."
  else
    return true, nil
  end
end

local function generate_session_name(default_name, new_session)
  local name = default_name
  local legal = false
  local err = nil
  while not legal do
    vim.ui.input({ prompt = "Input session name: ", default = name }, function(input)
      name = input and tostring(input)
    end)
    -- OPTIM: not automatically wrap? bug?
    -- notify.info "\n"
    if not name then
      -- ESC/C-c cancle
      return nil
    elseif not util.empty_str(name) then
      legal, err = check_session_name_char(name)
      if err then
        notify.error(err)
      else
        -- new session or rename to another name
        if new_session or name ~= default_name then
          legal, err = check_session_name_not_exists(name)
          if err then
            notify.error(err)
          end
        else
          -- cancle
          return nil
        end
      end
    else
      notify.warn "Empty input,auto generate."
      name = auto_generate_session_name(session)
      legal = true
    end
  end
  return name
end

function M.rename_session(old_name)
  local name = generate_session_name(old_name, false)
  if not name then
    notify.warn "Rename operation canceled."
    return false, nil
  end
  local success, _, err = io.rename(
    M.get_session_file_path(servers.get_server_selected().server, old_name),
    M.get_session_file_path(servers.get_server_selected().server, name)
  )
  if not success then
    notify.error(err)
    return success, err
  end
  if old_name == session_name then
    session_name = name
  end
  return success, name
end

function M.save_session()
  if not session or #session == 0 then
    notify.warn "No session to save."
    return
  end
  if not session_name then
    session_name = generate_session_name(_, true)
    if not session_name then
      notify.warn "Save operation canceled."
      return
    end
  end
  local _, err = io.write_json(M.get_session_file_path(servers.get_server_selected().server, session_name), session)
  if err then
    notify.error(err)
  else
    notify.info("Session saved: " .. session_name)
  end
end

function M.load_session(name)
  local json, err = io.read_json(M.get_session_file_path(servers.get_server_selected().server, name))
  if err then
    notify.error(err)
  else
    session = json
    session_name = name
  end
end

local function delete_session(name)
  local err = io.rm_file(M.get_session_file_path(servers.get_server_selected().server, name))
  if err then
    notify.error(err)
    return false
  end
  return true
end

function M.delete_session(name)
  if delete_session(name) then
    if name == session_name then
      M.clear_session(false)
      return name
    end
  end
end

function M.resume_session(bufnr)
  if bufnr and session and #session > 0 then
    local server = servers.get_server_selected()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
    local first = true
    local count
    for _, item in ipairs(session) do
      local lines = vim.split(item.content, "\n")
      if item.role == server.user_role then
        lines[1] = config.options.user_prompt .. " " .. lines[1]
      end
      if first then
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        count = 0
        first = false
      else
        count = vim.api.nvim_buf_line_count(bufnr)
        vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, lines)
      end
      util.add_line_separator(bufnr)

      -- set question highlight
      if item.role == server.user_role then
        hl.set_lines_highlights(bufnr, count, count + #lines)
      end
    end
  end
end

function M.load_sessions(server)
  if not server then
    notify.error "No server selected"
    return
  end
  local dir = config.options.base_config_dir .. "/" .. config.options.session_dir .. "/" .. server
  local files = io.get_files(dir)
  if files and #files > 0 then
    files = vim.tbl_map(function(file)
      return file:gsub(".json", "")
    end, files)
  end
  return files
end

local function session_filter(input, files)
  if files then
    return vim.tbl_filter(function(file)
      return file:find(input)
    end, files)
  end
end

local function data_filter(input, files)
  return session_filter(input, files)
end

local function clear_session_picker_win()
  M.input_buf = nil
  M.input_win = nil
  M.content_buf = nil
  M.content_win = nil
  M.selected_line = nil
end

function M.create_session_picker_win(enter_callback, close_callback)
  local session_win = config.options.session_picker_win
  local input_buf, input_win, content_buf, content_win = win.create_select_picker(
    session_win.width_percentage,
    session_win.input_height,
    session_win.content_height_percentage,
    session_win.winblend,
    "sessions",
    -- data_filter_wraper, delay load data
    function()
      local data = M.load_sessions(servers.get_server_selected().server) or {}
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
        if line ~= session_name then
          if #session > 0 then
            M.save_session()
          end
          M.load_session(line)
        end
        if enter_callback then
          enter_callback()
        end
      end
    end,
    -- close_callback
    function()
      clear_session_picker_win()
      if close_callback then
        close_callback()
      end
    end
  )

  M.input_buf = input_buf
  M.input_win = input_win
  M.content_buf = content_buf
  M.content_win = content_win

  return input_buf, input_win, content_buf, content_win
end
return M
