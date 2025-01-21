local M = {}

local util = require "llm.util"
local io = require "llm.io"
local notify = require "llm.notify"
local config = require "llm.config"
local session = require "llm.session"
local servers = require "llm.servers"
local win = require "llm.win"
local hl = require "llm.highlights"

local active_job = nil
local server_role = nil

local function handle_line(line, process_data)
  if not line then
    return false
  end
  local json = line:match "^data: (.+)$"
  if json then
    if json == "[DONE]" then
      return true
    end
    local data = vim.json.decode(json)
    vim.schedule(function()
      process_data(data)
    end)
  end
  return false
end

local function write_to_buf(content)
  local row, col = util.get_last_char_position(M.response_buf)
  local lines = vim.split(content, "\n")
  vim.api.nvim_buf_set_text(M.response_buf, row, col, row, col, lines)
  util.scroll_to_end(M.response_win, M.response_buf)
end

local function handle_response_prev()
  -- show loading sign
  vim.api.nvim_buf_set_lines(M.response_buf, -1, -1, false, { config.options.loading_mark })
end

-- handle first response
local first_response = false
local function handle_first_response()
  first_response = true
  local line_count = vim.api.nvim_buf_line_count(M.response_buf)
  -- delete loading line
  vim.api.nvim_buf_set_lines(M.response_buf, line_count - 1, line_count, false, { "" })
  session.record_start_point(M.response_buf)
end

-- post handler
local function handle_response_post()
  session.write_response_to_session(server_role, M.response_buf)
  util.add_line_separator(M.response_buf)
  if M.register_enter_handler then
    M.register_enter_handler()
  end
  active_job = nil
  server_role = nil
  first_response = false
end

local function handle_response(err, out)
  if not first_response then
    vim.schedule(handle_first_response)
  end
  if err then
    vim.schedule(function()
      notify.error(err, err)
    end)
    return
  end

  handle_line(out, function(data)
    local content
    if data.choices and data.choices[1] and data.choices[1].delta then
      content = data.choices[1].delta.content
      if data.choices[1].delta.role then
        server_role = data.choices[1].delta.role
      end
    end
    if content and content ~= vim.NIL then
      write_to_buf(content)
    end
  end)
end

local function send_request(input)
  local args = servers.get_server_selected().build_request(input)
  if active_job then
    active_job:shutdown()
    active_job = nil
  end
  active_job = io.curl(args, handle_response_prev, handle_response, handle_response_post)
  active_job:start()
end

-- input handler
local function handle_input()
  local input_lines = vim.api.nvim_buf_get_lines(M.input_buf, 0, -1, false)
  local input = table.concat(input_lines, "\n")
  if input == "" then
    return
  end

  -- add user prompt
  input_lines[1] = config.options.user_prompt .. " " .. input_lines[1]

  -- clear input
  vim.api.nvim_buf_set_lines(M.input_buf, 0, -1, false, {})

  local count

  -- write to response_buf
  if
    vim.api.nvim_buf_line_count(M.response_buf) == 1
    and vim.api.nvim_buf_get_lines(M.response_buf, 0, 1, false)[1] == ""
  then
    count = 0
    vim.api.nvim_buf_set_lines(M.response_buf, 0, -1, false, input_lines)
  else
    count = vim.api.nvim_buf_line_count(M.response_buf)
    vim.api.nvim_buf_set_lines(M.response_buf, -1, -1, false, input_lines)
  end

  -- set question highlight
  hl.set_lines_highlights(M.response_buf, count, count + #input_lines)

  util.add_line_separator(M.response_buf)

  util.scroll_to_end(M.response_win, M.response_buf)
  -- send to LLM
  local message = { role = servers.get_server_selected().user_role, content = input }
  session.write_request_to_session(message)
  -- send session
  if servers.get_server_selected().multi_round then
    --TODO: max_tokens
    send_request(session.get_session())
  else
    -- send current input
    send_request(message)
  end
end

local function clear_chat_win()
  M.response_buf = nil
  M.response_win = nil
  M.input_buf = nil
  M.input_win = nil
  -- get input
  M.clear = nil
  win.disable_auto_skip_when_insert()
end

local function record_input()
  M.input_cache = vim.api.nvim_buf_get_lines(M.input_buf, 0, -1, false)
end
-- submit input
local function submit()
  if not M.input_buf or not M.response_buf then
    return
  end
  handle_input()
end

-- 启动对话
function M.start_chat()
  local check = servers.check_options(servers.get_server_selected().server)
  if not check then
    return
  end
  if M.input_buf and M.response_buf then
    M.new()
    return
  end
  -- create chat window
  M.response_buf, M.response_win, M.input_buf, M.input_win, M.register_enter_handler =
    win.create_chat_win(servers.get_server_selected().server, submit, record_input, clear_chat_win)
  session.resume_session(M.response_buf)
  util.scroll_to_end(M.response_win, M.response_buf)

  if M.input_buf then
    -- resume cache
    if M.input_cache and #M.input_cache > 0 then
      vim.api.nvim_buf_set_lines(M.input_buf, 0, -1, false, M.input_cache)
    end

    -- functions that depend on chat windows
    M.clear = function()
      session.clear_session(false)
      vim.api.nvim_buf_set_lines(M.input_buf, 0, -1, false, {})
      vim.api.nvim_buf_set_lines(M.response_buf, 0, -1, false, {})
    end
  end
end

function M.save()
  session.save_session()
end

function M.new()
  session.clear_session(true)
  if not M.input_buf or not M.response_buf then
    M.start_chat()
  else
    vim.api.nvim_buf_set_lines(M.input_buf, 0, -1, false, {})
    vim.api.nvim_buf_set_lines(M.response_buf, 0, -1, false, {})
  end
end

function M.input_auth()
  servers.input_auth(servers.get_server_selected().server)
end

function M.select_sessions()
  if session.input_buf then
    return
  end
  --TODO:
  ---@diagnostic disable-next-line: unused-local
  local input_buf, input_win, content_buf, content_win = session.create_session_picker_win(
    -- enter callback
    function()
      if M.input_buf and M.response_buf then
        session.resume_session(M.response_buf)
      -- if M.input_win then
      --   vim.api.nvim_set_current_win(M.input_win)
      -- end
      else
        M.start_chat()
      end
    end,
    -- close callback
    function()
      M.delete_session = nil
      M.rename_session = nil
    end
  )

  -- functions that depend on session selection windows
  if input_buf then
    M.delete_session = function()
      local selected_line = vim.api.nvim_win_get_cursor(content_win)
      if selected_line then
        local lines = vim.api.nvim_buf_get_lines(content_buf, selected_line[1] - 1, selected_line[1], false)
        if lines and lines[1] and lines[1] ~= "" then
          local tip = "Delete session: "
            .. (vim.fn.strchars(lines[1]) > 20 and (vim.fn.strcharpart(lines[1], 0, 20) .. "...") or lines[1])
            .. "? (Y/N): "

          local answer = vim.fn.input(tip)
          answer = string.upper(answer)
          if answer == "Y" then
            local session_name = session.delete_session(lines[1])
            vim.api.nvim_buf_set_lines(content_buf, selected_line[1] - 1, selected_line[1], false, {})
            -- current session
            if session_name and M.response_buf then
              vim.api.nvim_buf_set_lines(M.response_buf, 0, -1, false, {})
            end
          elseif answer == "N" then
          elseif answer == "" then
          else
            notify.warn "Invalid input. Please enter Y or N."
          end
        end
      end
    end

    M.rename_session = function()
      local selected_line = vim.api.nvim_win_get_cursor(content_win)
      if selected_line then
        local lines = vim.api.nvim_buf_get_lines(content_buf, selected_line[1] - 1, selected_line[1], false)
        if lines and lines[1] and lines[1] ~= "" then
          local success, str = session.rename_session(lines[1])
          if success then
            vim.api.nvim_buf_set_lines(content_buf, selected_line[1] - 1, selected_line[1], false, { str })
          end
        end
      end
    end
  end
end

function M.select_server()
  if servers.input_buf then
    return
  end
  servers.create_server_picker_win(
    -- enter callback
    function()
      local opened_wins = { M.input_win, M.response_win, session.input_win, session.response_win }
      for _, win_id in ipairs(opened_wins) do
        if win_id and vim.api.nvim_win_is_valid(win_id) then
          vim.api.nvim_win_close(win_id, true)
        end
      end
    end,
    -- close callback
    nil
  )
end

return M
