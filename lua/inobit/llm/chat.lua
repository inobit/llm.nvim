local util = require "inobit.llm.util"
local config = require "inobit.llm.config"
local SessionManager = require "inobit.llm.session"
local ServerManager = require "inobit.llm.server"
local win = require "inobit.llm.win"
local hl = require "inobit.llm.highlights"
local Spinner = require("inobit.llm.spinner").FloatSpinner

---@class llm.chat.ActiveChatBuffer
---@field input_bufnr? integer
---@field response_bufnr? integer

---@class llm.Chat
---@field win llm.win.ChatWin
---@field session llm.Session
---@field server llm.Server
---@field requesting? Job
---@field spinner llm.Spinner
local Chat = {}
Chat.__index = Chat

---@class llm.chat.ChatManager
---@field chats table<string, llm.Chat>
---@field last_used_chat llm.Chat
local ChatManager = {}
ChatManager.__index = ChatManager
ChatManager.chats = {}

---used for lualine status
---@return integer
function ChatManager:has_chats()
  return #vim.tbl_keys(self.chats)
end

---@return integer
function ChatManager:has_active_chats()
  return #vim.tbl_filter(function(chat)
    return chat.requesting ~= nil
  end, self.chats)
end

---@param session? llm.Session
function ChatManager:new(session)
  local exists_chat, exists_session, new_chat
  exists_session = session
  if exists_session then
    exists_chat = self.chats[exists_session.id]
  else
    exists_chat = self.last_used_chat
  end

  if exists_chat then
    if exists_chat ~= self.last_used_chat or not vim.api.nvim_win_is_valid(exists_chat.win.floats.response.winid) then
      -- exists chat,change the chat's win options
      new_chat = Chat:new(exists_chat)
    end
  else
    -- new chat,exists session or new session
    new_chat = Chat:new(nil, exists_session)
  end

  if new_chat then
    self.chats[new_chat.session.id] = new_chat
    vim.schedule(function()
      if self.last_used_chat and self.last_used_chat ~= new_chat then
        win.WinStack:delete(self.last_used_chat.win.floats.response.winid)
        win.WinStack:delete(self.last_used_chat.win.floats.input.winid)
        self.last_used_chat.win.floats.response:close()
      end
      self.last_used_chat = new_chat
    end)
  end
end

---@param exists_chat? llm.Chat
---@param exists_session? llm.Session
---@return llm.Chat
function Chat:new(exists_chat, exists_session)
  local this = exists_chat
  if this then
    -- update win
    this.win = win.ChatWin:new {
      title = this.session.server .. "@" .. this.session.model,
      input_bufnr = this.win.floats.input.bufnr,
      response_bufnr = this.win.floats.response.bufnr,
    }
  else
    this = setmetatable({}, Chat)
    this.session = exists_session
      or SessionManager:new_session(ServerManager.chat_server.server, ServerManager.chat_server.model)
    this.server = ServerManager.servers[this.session.server .. "@" .. this.session.model]
    this.win = win.ChatWin:new {
      title = this.session.server .. "@" .. this.session.model,
    }
  end
  this.spinner = Spinner:new(this.win.floats.input)
  if this.requesting then
    this.spinner:start()
  else
    this:_register_submit_keymap()
  end

  this:_resume_session()
  this:_register_new_chat_keymap()
  return this
end

---@private
---@return integer
function Chat:_set_header()
  local headers = {
    string.format("- **server@model**: %s@%s", self.session.server, self.session.model),
    string.format("- **create time**: %s", os.date("%Y-%m-%d %H:%M:%S", self.session.create_time)),
    string.format("- **session name**: %s", self.session.name),
    string.format("- **session id**: %s", self.session.id),
  }
  if vim.api.nvim_buf_get_lines(self.win.floats.response.bufnr, 0, 1, false)[1] ~= "" then
    vim.api.nvim_buf_set_lines(self.win.floats.response.bufnr, 0, 4, false, headers)
  else
    self:_write_lines_to_response(headers)
  end
  return #headers
end

---@private
function Chat:_resume_session()
  vim.api.nvim_set_current_win(self.win.floats.response.winid)
  self:_render()
  local head_len = self:_set_header()
  if vim.api.nvim_buf_line_count(self.win.floats.response.bufnr) > head_len + 1 then
    -- do nothing when the session is not empty
    vim.api.nvim_set_current_win(self.win.floats.input.winid)
    return
  end
  if not vim.tbl_isempty(self.session.content) then
    for _, message in ipairs(self.session.content) do
      if message.role == (self.server.user_role or "user") then
        -- user message
        self:_write_lines_to_response(self:_build_input_render_style(vim.split(message.content, "\n")))
      else
        -- assistant message
        if message.reasoning_content then
          -- thinking content
          local thinking_lines = vim.split(message.reasoning_content, "\n")
          table.insert(thinking_lines, 1, "[!Tip] Thought content")
          self:_write_lines_to_response(vim
            .iter(thinking_lines)
            :map(function(line)
              return "> " .. line
            end)
            :totable())
        else
          -- answer content
          local answer_lines = vim.split(message.content, "\n")
          self:_write_lines_to_response(answer_lines)
        end
      end
    end
  end
  vim.api.nvim_set_current_win(self.win.floats.input.winid)
end

---stop request
---@param signal llm.server.StopSignal
function Chat:_close(signal)
  if self.requesting then
    if signal ~= 0 then
      self.requesting:shutdown(signal)
    end
    self.requesting = nil
  end
end

function Chat:_render()
  local status, module = pcall(require, "render-markdown")
  if status then
    module.buf_enable()
  end
end

---@private
---use <C-C> to stop request
---use <C-S> to save session
--WARN: the buffer will be reused, and without rebinding, the reference of 'self' may cause confusion.
function Chat:_register_stop_and_save_keymap()
  local bufnrs = { self.win.floats.input.bufnr, self.win.floats.response.bufnr }
  for _, bufnr in ipairs(bufnrs) do
    vim.keymap.set({ "n", "i" }, "<C-C>", function()
      self:_close(1000)
    end, { buffer = bufnr, noremap = true, silent = true })
    vim.keymap.set({ "n", "i" }, "<C-S>", function()
      self.session:save()
    end, { buffer = bufnr, noremap = true, silent = true })
  end
end

---@private
function Chat:_remove_stop_request_keymap()
  local bufnrs = { self.win.floats.input.bufnr, self.win.floats.response.bufnr }
  for _, bufnr in ipairs(bufnrs) do
    pcall(vim.keymap.del, { "n", "i" }, "<C-C>", { buffer = bufnr })
  end
end

---@private
---use <C-N> to create new chat
function Chat:_register_new_chat_keymap()
  local bufnrs = { self.win.floats.input.bufnr, self.win.floats.response.bufnr }
  for _, bufnr in ipairs(bufnrs) do
    vim.keymap.set({ "n", "i" }, "<C-N>", function()
      -- force creation of new chat
      ChatManager:new(SessionManager:new_session(ServerManager.chat_server.server, ServerManager.chat_server.model))
    end, { buffer = bufnr, noremap = true, silent = true })
  end
end

---@private
function Chat:_register_submit_keymap()
  local function submit()
    self:_remove_submit_keymap()
    self:_input_enter_handler()
  end
  vim.keymap.set("n", "<CR>", submit, { buffer = self.win.floats.input.bufnr, noremap = true, silent = true })
  -- <C-CR>
  vim.keymap.set("i", "<NL>", submit, { buffer = self.win.floats.input.bufnr, noremap = true, silent = true })
end

---@private
function Chat:_remove_submit_keymap()
  pcall(vim.keymap.del, "n", "<CR>", { buffer = self.win.floats.input.bufnr, noremap = true, silent = true })
  pcall(vim.keymap.del, "i", "<NL>", { buffer = self.win.floats.input.bufnr, noremap = true, silent = true })
end

---@private
function Chat:_add_round_separator()
  self:_write_lines_to_response { "", "**response ended!**" }
end

---@private
function Chat:_add_long_time_separator()
  self:_write_lines_to_response { "----" }
end

---@private
function Chat:_refresh_response_cursor()
  if vim.api.nvim_win_is_valid(self.win.floats.response.winid) then
    local new_row, new_col = util.get_last_char_position(self.win.floats.response.bufnr)
    vim.api.nvim_win_set_cursor(self.win.floats.response.winid, { new_row, new_col })
  end
end

---@private
---@param input_lines string[]
---@return string[]
function Chat:_build_input_render_style(input_lines)
  local lines = vim.deepcopy(input_lines)
  lines[1] = config.options.user_prompt .. " " .. lines[1]
  return lines
end

---@private
---@param head_line integer
function Chat:_update_thinking_head(head_line)
  vim.api.nvim_buf_set_lines(
    self.win.floats.response.bufnr,
    head_line,
    head_line + 1,
    false,
    { "> [!Tip] Thought content" }
  )
end

---@private
---@param lines string[]
---@param add_margin_bottom? boolean default true
function Chat:_write_lines_to_response(lines, add_margin_bottom)
  if
    vim.api.nvim_buf_line_count(self.win.floats.response.bufnr) == 1
    and vim.api.nvim_buf_get_lines(self.win.floats.response.bufnr, 0, 1, false)[1] == ""
  then
    vim.api.nvim_buf_set_lines(self.win.floats.response.bufnr, 0, -1, false, lines)
  else
    vim.api.nvim_buf_set_lines(self.win.floats.response.bufnr, -1, -1, false, lines)
  end
  if add_margin_bottom == nil or add_margin_bottom then
    -- add empty line
    vim.api.nvim_buf_set_lines(self.win.floats.response.bufnr, -1, -1, false, { "" })
  end
  self:_refresh_response_cursor()
  hl.mark_sections(self.win.floats.response.bufnr)
end

---@private
---@param content string
---@param start_think {value: boolean, in_line: integer}
function Chat:_write_reason_text_to_response(content, start_think)
  local bufnr = self.win.floats.response.bufnr
  local row, col = util.get_last_char_position(bufnr)
  -- thinking content style
  content = content:gsub("\n", "\n> ")
  -- thinking head style
  if start_think.value then
    content = "\n> [!Tip] Thinking\n> " .. content
    start_think.value = false
    -- save thinking head line
    start_think.in_line = row
  end
  local lines = vim.split(content, "\n")
  vim.api.nvim_buf_set_text(bufnr, row - 1, col, row - 1, col, lines)
  self:_refresh_response_cursor()
end

---@private
---@param content string
---@param start_answer {value: boolean}
---@param start_think {value: boolean}
function Chat:_write_answer_text_to_response(content, start_answer, start_think)
  if start_answer.value then
    -- new line
    content = (start_think.value and "\n" or "\n\n") .. content
    start_answer.value = false
  end
  local bufnr = self.win.floats.response.bufnr
  local row, col = util.get_last_char_position(bufnr)
  local lines = vim.split(content, "\n")
  vim.api.nvim_buf_set_text(bufnr, row - 1, col, row - 1, col, lines)
  self:_refresh_response_cursor()
end

---handle response(stream mode)
---@private
---@param res string
---@param response_message llm.session.Message
---@param response_reasoning_message llm.session.Message
---@param start_think {value: boolean, in_line: integer}
---@param start_answer {value: boolean}
---@param parse_error fun(string)
function Chat:_response_handler(
  res,
  response_message,
  response_reasoning_message,
  start_think,
  start_answer,
  parse_error
)
  if not res or res == "" then
    return
  end

  local chunk = res:match "^data:%s(.+)$"

  -- not match normal response
  if chunk == nil then
    parse_error(res)
    return
  end

  -- response end
  if chunk == "[DONE]" then
    return
  end

  -- trying to parse chunk
  _, chunk = pcall(vim.json.decode, chunk)
  if chunk == nil then
    parse_error(string.format("parse error: %s", res))
    return
  end

  -- handle chunk
  if chunk.choices and chunk.choices[1] and chunk.choices[1].delta then
    if chunk.choices[1].delta.reasoning_content and chunk.choices[1].delta.reasoning_content ~= vim.NIL then
      -- update reasoning message
      response_reasoning_message.role = chunk.choices[1].delta.role or response_reasoning_message.role
      local cleaned_str = chunk.choices[1].delta.reasoning_content:gsub("\n\n", "\n")
      response_reasoning_message.reasoning_content = response_reasoning_message.reasoning_content .. cleaned_str
      -- write reasoning content to response buf
      self:_write_reason_text_to_response(cleaned_str, start_think)
    else
      if start_think.in_line then
        self:_update_thinking_head(start_think.in_line)
        start_think.in_line = nil
      end
      -- update response message
      response_message.role = chunk.choices[1].delta.role or response_message.role
      local cleaned_str = chunk.choices[1].delta.content:gsub("\n\n", "\n")
      response_message.content = response_message.content .. cleaned_str
      -- write response content to response buf
      self:_write_answer_text_to_response(cleaned_str, start_answer, start_think)
    end
  end
end

---@private
function Chat:_handle_session()
  -- handle last 2 elements
  local len = #self.session.content
  if self.session.content[len].content and self.session.content[len].content == "" then
    table.remove(self.session.content, len)
  end
  if
    len > 1
    and self.session.content[len - 1].reasoning_content
    and self.session.content[len - 1].reasoning_content == ""
  then
    table.remove(self.session.content, len - 1)
  end
  -- auto save
  self.session:save()
end

---@private
function Chat:_after_begin()
  self.spinner:start()
  -- self:_add_request_separator()
  self:_register_stop_and_save_keymap()
  if vim.api.nvim_win_is_valid(self.win.floats.response.winid) then
    vim.api.nvim_set_current_win(self.win.floats.response.winid)
  end
  if (os.difftime(os.time(), self.session.update_time)) > 60 * 60 then
    self:_add_long_time_separator()
  end
end

---@private
function Chat:_after_stop()
  self:_handle_session()
  self.spinner:stop()
  self:_remove_stop_request_keymap()
  self:_register_submit_keymap()
  self:_close(0)
end

---@private
function Chat:_input_enter_handler()
  local input_lines = vim.api.nvim_buf_get_lines(self.win.floats.input.bufnr, 0, -1, false)
  if input_lines[1] == "" then
    return
  end

  -- construct response message and reasoning message
  local response_message = { role = "assistant", content = "" }
  local response_reasoning_message = { role = "assistant", reasoning_content = "" }

  -- start response sign
  local start_think = { value = true }
  local start_answer = { value = true }

  ---@param error llm.server.Error
  local function on_error(error)
    local header = "[!CAUTION] Error!"
    if error.exit == 1000 or error.exit == 1001 then
      header = "[!WARNING] Warning!"
    end
    local err = string.format("%s%s%s", header, "\n", error.message)
    local err_lines = vim.split(err, "\n")
    err_lines = vim
      .iter(err_lines)
      :map(function(line)
        return "> " .. line
      end)
      :totable()
    table.insert(err_lines, 1, "")
    self:_write_lines_to_response(err_lines)
    self:_after_stop()
  end

  ---@param error string
  local function parse_error(error)
    -- Comment lines in event streams that begin with a colon
    if error:match "^:%s" then
      -- maybe keep alive message,just ignore
      return
    end
    ---@type llm.server.Error
    local err_obj = {
      exit = 1002,
      message = error,
      stderr = "",
    }
    if error:match "^{.*}$" then
      local status, msg = pcall(vim.json.decode, error)
      if status then
        msg = msg.error and (msg.error.message or msg.error) or msg
        err_obj.message = type(msg) == "string" and msg or vim.inspect(msg)
      end
    end
    on_error(err_obj)
  end

  ---on stream response
  ---@param err string
  ---@param data string
  local function on_stream(err, data)
    -- handle error
    if err then
      on_error { message = err, stderr = "", exit = 0 }
    -- handle response data
    else
      self:_response_handler(data, response_message, response_reasoning_message, start_think, start_answer, parse_error)
    end
  end

  local function on_exit()
    self:_after_stop()
    self:_add_round_separator()
  end

  ---construct input message
  ---@type llm.session.Message
  local input_message = { role = self.server.user_role or "user", content = table.concat(input_lines, "\n") }
  -- construct send content
  ---@type llm.session.Message[]
  local send_content = { input_message }
  if self.server.multi_round then
    send_content = self.session:multi_round_filter()
    table.insert(send_content, input_message)

    -- deepseek-reasoner does not support...You should interleave the user/assistant messages in the message sequence
    -- filter no response question
    local role = ""
    for i = #send_content, 1, -1 do
      if send_content[i].role ~= role then
        role = send_content[i].role
      else
        -- For consecutive identical roles, only the last one is kept, i.e., only the last question is sent
        table.remove(send_content, i)
      end
    end
  end

  ---@type llm.server.RequestOpts
  local opts = self
    .server--[[@as llm.OpenAIServer]]
    :build_request_opts(send_content, { stream = true })
  opts.callback = on_exit
  opts.stream = on_stream
  opts.on_error = on_error

  -- send request,force stream mode
  local job = self.server:request(opts)

  if job and job:is_job() then
    self.requesting = job --[[@as Job]]
  end

  self:_after_begin()

  -- add input to session
  self.session:add_message(input_message)
  -- add reasoning message to session
  self.session:add_message(response_reasoning_message)
  -- add response message to session
  self.session:add_message(response_message)
  -- clear input
  vim.api.nvim_buf_set_lines(self.win.floats.input.bufnr, 0, -1, false, {})
  -- write input to response buf
  self:_write_lines_to_response(self:_build_input_render_style(input_lines))
end

return ChatManager
