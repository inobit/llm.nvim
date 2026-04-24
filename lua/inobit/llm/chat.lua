local util = require "inobit.llm.util"
local config = require "inobit.llm.config"
local SessionManager = require "inobit.llm.session"
local ServerManager = require "inobit.llm.server"
local win = require "inobit.llm.win"
local hl = require "inobit.llm.highlights"
local notify = require "inobit.llm.notify"
local Spinner = require("inobit.llm.spinner").FloatSpinner

local RETRY_NAMESPACE = hl.NAMESPACE
local RETRY_HINT_EXTMARK_ID = 999999999 -- special id for retry hint virtual text

---@alias llm.Chat.BoolRef boolean
---@alias llm.Chat.BoolPayload {value: boolean, payload: any}
---@alias llm.Chat.ThinkTag {is: boolean, end_think: boolean, payload?: string}

---@class llm.chat.ActiveChatBuffer
---@field input_bufnr? integer
---@field response_bufnr? integer

---@class llm.Chat
---@field win llm.win.BaseChatWin
---@field session llm.Session
---@field server llm.Server
---@field requesting? llm.RequestJob
---@field spinner llm.Spinner
---@field start_think llm.Chat.BoolPayload
---@field start_answer llm.Chat.BoolRef
---@field think_tag llm.Chat.ThinkTag
---@field no_first_res_in_turn boolean
---@field current_response llm.session.Message
---@field current_response_reasoning llm.session.Message
local Chat = {}
Chat.__index = Chat

--- Check if Chat is in the foreground (window active)
---@return boolean
function Chat:is_foreground()
  return vim.api.nvim_win_is_valid(self.win.wins.response.winid) or vim.api.nvim_win_is_valid(self.win.wins.input.winid)
end

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

  -- For vsplit layout, close old windows first to avoid layout conflicts
  local chat_layout = config.options.chat_layout
  if chat_layout == "vsplit" and self.last_used_chat and self.last_used_chat ~= exists_chat then
    local old_response_win = self.last_used_chat.win.wins.response.winid
    local old_input_win = self.last_used_chat.win.wins.input.winid
    win.WinStack:delete(old_response_win)
    win.WinStack:delete(old_input_win)
    pcall(vim.api.nvim_win_close, old_input_win, true)
    pcall(vim.api.nvim_win_close, old_response_win, true)
  end

  if exists_chat then
    if exists_chat ~= self.last_used_chat or not vim.api.nvim_win_is_valid(exists_chat.win.wins.response.winid) then
      -- exists chat,change the chat's win options
      new_chat = Chat:new(exists_chat)
    end
  else
    -- new chat,exists session or new session
    new_chat = Chat:new(nil, exists_session)
  end

  if new_chat then
    -- Close old windows for float layout (vsplit already handled above)
    if chat_layout ~= "vsplit" and self.last_used_chat and self.last_used_chat ~= new_chat then
      win.WinStack:delete(self.last_used_chat.win.wins.response.winid)
      win.WinStack:delete(self.last_used_chat.win.wins.input.winid)
      self.last_used_chat.win.wins.response:close()
    end
    self.chats[new_chat.session.id] = new_chat
    self.last_used_chat = new_chat
  end
end

---@param session llm.SessionIndex
function ChatManager:delete_chat(session)
  local chat = self.chats[session.id]
  if not chat then
    return
  end

  -- 1. Terminate ongoing request
  if chat.requesting then
    chat:_close(true)
    chat.requesting = nil
  end

  -- 2. Cancel title generation job
  if chat.session and chat.session._title_generation_job then
    chat.session._title_generation_job:kill()
    chat.session._title_generation_job = nil
  end

  -- 3. Close windows if foreground
  if chat:is_foreground() then
    -- Close chat windows
    pcall(vim.api.nvim_win_close, chat.win.wins.input.winid, true)
    pcall(vim.api.nvim_win_close, chat.win.wins.response.winid, true)
  end

  -- 4. Remove from chat manager
  self.chats[session.id] = nil
  if self.last_used_chat == chat then
    self.last_used_chat = nil
  end
end

---@param exists_chat? llm.Chat
---@param exists_session? llm.Session
---@return llm.Chat
function Chat:new(exists_chat, exists_session)
  local this = exists_chat
  if this then
    -- update win - choose layout based on config
    local chat_layout = config.options.chat_layout
    if chat_layout == "vsplit" then
      this.win = win.SplitChatWin:new {
        title = this.session.server .. "@" .. this.session.model,
        input_bufnr = this.win.wins.input.bufnr,
        response_bufnr = this.win.wins.response.bufnr,
      }
    else
      this.win = win.ChatWin:new {
        title = this.session.server .. "@" .. this.session.model,
        input_bufnr = this.win.wins.input.bufnr,
        response_bufnr = this.win.wins.response.bufnr,
      }
    end
  else
    this = setmetatable({}, Chat)
    this.session = exists_session
      or SessionManager:new_session(ServerManager.chat_server.server, ServerManager.chat_server.model)
    this.server = ServerManager.servers[this.session.server .. "@" .. this.session.model]

    -- Choose window type based on config
    local chat_layout = config.options.chat_layout
    if chat_layout == "vsplit" then
      this.win = win.SplitChatWin:new {
        title = this.session.server .. "@" .. this.session.model,
      }
    else
      this.win = win.ChatWin:new {
        title = this.session.server .. "@" .. this.session.model,
      }
    end
  end
  this.spinner = Spinner:new(this.win.wins.input)
  if this.requesting then
    this.spinner:start()
  else
    this:_register_submit_keymap()
  end

  this:_resume_session()
  this:_register_new_chat_keymap()
  this:_register_nav_keymaps()
  this:_register_retry_keymap()
  this:_register_cursor_moved_autocmd()
  return this
end

---@private
---@return integer
function Chat:_set_header()
  local headers = {
    string.format("- **server@model**: %s@%s", self.session.server, self.session.model),
    string.format("- **create time**: %s", os.date("%Y-%m-%d %H:%M:%S", self.session.create_time)),
    string.format("- **session title**: %s", self.session.title),
    string.format("- **session id**: %s", self.session.id),
  }
  if vim.api.nvim_buf_get_lines(self.win.wins.response.bufnr, 0, 1, false)[1] ~= "" then
    vim.api.nvim_buf_set_lines(self.win.wins.response.bufnr, 0, 4, false, headers)
  else
    self:_write_lines_to_response(headers)
  end
  return #headers
end

---@private
function Chat:_resume_session()
  vim.api.nvim_set_current_win(self.win.wins.response.winid)
  self:_render()
  -- Clear old extmarks and buffer content before restoring
  hl.clear_extmarks(self.win.wins.response.bufnr)
  local head_len = self:_set_header()
  -- Clear everything after header
  vim.api.nvim_buf_set_lines(self.win.wins.response.bufnr, head_len, -1, false, {})
  -- Re-render all messages from session
  if not vim.tbl_isempty(self.session.content) then
    for idx, message in ipairs(self.session.content) do
      if message.role == (self.server.user_role or "user") then
        -- user message
        local start_line = vim.api.nvim_buf_line_count(self.win.wins.response.bufnr)
        self:_write_lines_to_response(self:_build_input_render_style(vim.split(message.content, "\n")))
        local end_line = vim.api.nvim_buf_line_count(self.win.wins.response.bufnr)
        -- Set extmark with highlight for this user message (end_row exclusive, so use end_line - 1 to exclude empty line)
        self:_set_user_message_extmark(start_line, end_line - 1, idx)
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
  vim.api.nvim_set_current_win(self.win.wins.input.winid)
end

---stop request
---@param should_kill boolean if true, kill the job; if false, just clear the reference
---@param reason? string cancel reason to display in response window
function Chat:_close(should_kill, reason)
  if self.requesting then
    if should_kill then
      self.requesting:kill(9, reason)
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
  local bufnrs = { self.win.wins.input.bufnr, self.win.wins.response.bufnr }
  for _, bufnr in ipairs(bufnrs) do
    vim.keymap.set({ "n", "i" }, "<C-C>", function()
      self:_close(true, "User canceled")
    end, { buffer = bufnr, noremap = true, silent = true })
    vim.keymap.set({ "n", "i" }, "<C-S>", function()
      self.session:save()
    end, { buffer = bufnr, noremap = true, silent = true })
  end
end

---@private
function Chat:_remove_stop_request_keymap()
  local bufnrs = { self.win.wins.input.bufnr, self.win.wins.response.bufnr }
  for _, bufnr in ipairs(bufnrs) do
    pcall(vim.keymap.del, { "n", "i" }, "<C-C>", { buffer = bufnr })
  end
end

---@private
---use <C-N> to create new chat
function Chat:_register_new_chat_keymap()
  local bufnrs = { self.win.wins.input.bufnr, self.win.wins.response.bufnr }
  for _, bufnr in ipairs(bufnrs) do
    vim.keymap.set({ "n", "i" }, "<C-N>", function()
      -- Check if current session has content
      if #self.session.content > 0 then
        self:_prompt_fork_or_new()
      else
        -- Empty session, create new one directly
        ChatManager:new(SessionManager:new_session(ServerManager.chat_server.server, ServerManager.chat_server.model))
      end
    end, { buffer = bufnr, noremap = true, silent = true })
  end
end

---@private
function Chat:_prompt_fork_or_new()
  local choices = {
    "n. New session",
    "5. Fork last 5 rounds",
    "10. Fork last 10 rounds",
    "a. Fork all",
    "c. Custom range",
  }

  vim.ui.select(choices, {
    prompt = "Continue based on existing session?",
  }, function(choice)
    if not choice then
      return
    end

    local new_session
    local total_rounds = math.floor(#self.session.content / 2)
    if choice:match "^n" then
      -- New session
      new_session = SessionManager:new_session(ServerManager.chat_server.server, ServerManager.chat_server.model)
    elseif choice:match "^5" then
      -- Fork last 5 rounds
      new_session =
        SessionManager:fork_session(self.session, { start = math.max(1, total_rounds - 4), ["end"] = total_rounds })
    elseif choice:match "^10" then
      -- Fork last 10 rounds
      new_session =
        SessionManager:fork_session(self.session, { start = math.max(1, total_rounds - 9), ["end"] = total_rounds })
    elseif choice:match "^a" then
      -- Fork all
      new_session = SessionManager:fork_session(self.session, "all")
    elseif choice:match "^c" then
      -- Custom range
      self:_prompt_custom_fork_range()
      return
    end

    if new_session then
      ChatManager:new(new_session)
    end
  end)
end

---@private
function Chat:_prompt_custom_fork_range()
  local total_msgs = #self.session.content
  local total_rounds = math.floor(total_msgs / 2)

  vim.ui.input({
    prompt = string.format("Enter round(s) (1-%d, e.g., 3, 3-5, or 2-): ", total_rounds),
  }, function(input)
    if not input or input == "" then
      return
    end

    -- Parse: single round "3" or range "start-end" or "start-"
    local start_round, end_round = input:match "^(%d+)%s*%-?%s*(%d*)$"
    if not start_round then
      notify.warn("invalid format", "use format: 3, 3-5, or 2-")
      return
    end

    start_round = tonumber(start_round)
    -- If no end specified, use start_round (single round)
    end_round = end_round ~= "" and tonumber(end_round) or start_round

    if not start_round or start_round < 1 or start_round > total_rounds then
      notify.warn("invalid start round", string.format("must be between 1 and %d", total_rounds))
      return
    end

    if end_round < start_round or end_round > total_rounds then
      notify.warn("invalid end round", string.format("must be between %d and %d", start_round, total_rounds))
      return
    end

    -- Convert round numbers to message indices (each round = 2 messages)
    local start_idx = (start_round - 1) * 2 + 1
    local end_idx = end_round * 2

    local new_session = SessionManager:fork_session(self.session, { start = start_idx, ["end"] = end_idx })
    if new_session then
      ChatManager:new(new_session)
    end
  end)
end

---@private
---@param direction "next" | "prev"
function Chat:_navigate_to_question(direction)
  local bufnr = self.win.wins.response.bufnr
  local prompt = config.options.user_prompt
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local cur_pos = vim.api.nvim_win_get_cursor(self.win.wins.response.winid)
  local cur_line = cur_pos[1]

  local function find_next_question_line(start_line, step)
    local line = start_line + step
    while line >= 1 and line <= line_count do
      local line_text = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1]
      if line_text and vim.startswith(line_text, prompt) then
        return line
      end
      line = line + step
    end
    return nil
  end

  local target_line
  if direction == "next" then
    target_line = find_next_question_line(cur_line, 1)
    if not target_line then
      target_line = find_next_question_line(0, 1)
    end
  else
    target_line = find_next_question_line(cur_line, -1)
    if not target_line then
      target_line = find_next_question_line(line_count + 1, -1)
    end
  end

  if target_line then
    vim.api.nvim_win_set_cursor(self.win.wins.response.winid, { target_line, 0 })
  end
end

---@private
function Chat:_register_nav_keymaps()
  local bufnr = self.win.wins.response.bufnr
  local nav = config.options.nav

  vim.keymap.set("n", nav.next_question, function()
    self:_navigate_to_question "next"
  end, { buffer = bufnr, noremap = true, silent = true, desc = "LLM: go to next question" })

  vim.keymap.set("n", nav.prev_question, function()
    self:_navigate_to_question "prev"
  end, { buffer = bufnr, noremap = true, silent = true, desc = "LLM: go to previous question" })
end

---register retry keymap on response buffer
function Chat:_register_retry_keymap()
  local bufnr = self.win.wins.response.bufnr
  local key = config.options.retry_key
  vim.keymap.set("n", key, function()
    self:_handle_retry()
  end, { buffer = bufnr, noremap = true, silent = true })
end

---@private
---register CursorMoved autocmd to show/hide retry hint
function Chat:_register_cursor_moved_autocmd()
  local bufnr = self.win.wins.response.bufnr
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = bufnr,
    callback = function()
      self:_update_retry_hint()
    end,
  })
end

---@private
---update retry hint virtual text based on cursor position
function Chat:_update_retry_hint()
  local bufnr = self.win.wins.response.bufnr
  local cursor_row = vim.api.nvim_win_get_cursor(self.win.wins.response.winid)[1] - 1 -- 0-indexed

  -- Check if there's an extmark at cursor row
  local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, RETRY_NAMESPACE, { cursor_row, 0 }, { cursor_row, -1 }, {
    details = false,
  })

  -- Clear existing hint first
  self:_remove_retry_hint()

  if #extmarks > 0 then
    -- Show hint at the end of current line
    local line = vim.api.nvim_buf_get_lines(bufnr, cursor_row, cursor_row + 1, false)[1] or ""
    local col = #line
    vim.api.nvim_buf_set_extmark(bufnr, RETRY_NAMESPACE, cursor_row, 0, {
      virt_text = { { config.options.retry_hint_text, "Comment" } },
      virt_text_pos = "eol",
      id = RETRY_HINT_EXTMARK_ID,
    })
  end
end

---@private
---remove retry hint virtual text
function Chat:_remove_retry_hint()
  local bufnr = self.win.wins.response.bufnr
  -- Clear hint extmark
  pcall(vim.api.nvim_buf_del_extmark, bufnr, RETRY_NAMESPACE, RETRY_HINT_EXTMARK_ID)
end

---@private
function Chat:_register_submit_keymap()
  local function submit()
    self:_remove_submit_keymap()
    self:_input_enter_handler()
  end
  vim.keymap.set("n", "<CR>", submit, { buffer = self.win.wins.input.bufnr, noremap = true, silent = true })
  -- <C-CR>
  vim.keymap.set("i", "<NL>", submit, { buffer = self.win.wins.input.bufnr, noremap = true, silent = true })
end

---@private
function Chat:_remove_submit_keymap()
  pcall(vim.keymap.del, "n", "<CR>", { buffer = self.win.wins.input.bufnr, noremap = true, silent = true })
  pcall(vim.keymap.del, "i", "<NL>", { buffer = self.win.wins.input.bufnr, noremap = true, silent = true })
end

---@private
---handle retry action
function Chat:_handle_retry()
  if self.requesting then
    -- Block retry if there's an ongoing request
    return
  end

  local bufnr = self.win.wins.response.bufnr
  local cursor_row = vim.api.nvim_win_get_cursor(self.win.wins.response.winid)[1] - 1 -- 0-indexed

  -- Find extmark at cursor row
  local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, RETRY_NAMESPACE, { cursor_row, 0 }, { cursor_row, -1 }, {
    details = false,
  })

  if #extmarks == 0 then
    return
  end

  -- Get message_index from extmark id
  local message_index = extmarks[1][1] -- extmark id is the message_index
  local message = self.session.content[message_index]

  if not message or message.role ~= (self.server.user_role or "user") then
    return
  end

  -- Get the last user message index in session
  local last_user_index = nil
  for i = #self.session.content, 1, -1 do
    if self.session.content[i].role == (self.server.user_role or "user") then
      last_user_index = i
      break
    end
  end

  -- Check if this is the last user message and there's no answer after it
  local is_last_unanswered = message_index == last_user_index
    and (
      message_index == #self.session.content
      or self.session.content[message_index + 1].role == (self.server.user_role or "user")
    )

  if is_last_unanswered then
    -- Direct retry: remove the empty response messages and re-submit
    -- Remove reasoning and response messages for this turn
    while #self.session.content > message_index do
      table.remove(self.session.content)
    end
    -- Re-submit (message already in session, is_new=false)
    self:_submit_message(message, false, nil)
  else
    -- Historical retry: append to end of session
    -- Create a new message with same content
    local retry_message = {
      role = message.role,
      content = message.content,
    }
    -- Submit (is_new=true will add to session)
    self:_submit_message(retry_message, true, nil)
  end
end

---@private
---@param message llm.session.Message
---@param is_new_message boolean if true, message needs to be added to session
---@param input_lines? string[] original input lines for UI rendering (only for new messages)
function Chat:_submit_message(message, is_new_message, input_lines)
  -- init response status
  self:_init_response_status()

  -- If new message, add to session first (needed for multi_round_filter)
  if is_new_message then
    self.session:add_message(message)
  end

  -- construct send content
  ---@type llm.session.Message[]
  local send_content = { message }
  if self.server.multi_round then
    send_content = self.session:multi_round_filter()
    -- For new messages, message is already in session via multi_round_filter
    -- No need to insert again

    -- deepseek-reasoner does not support consecutive same roles
    local role = ""
    for i = #send_content, 1, -1 do
      if send_content[i].role ~= role then
        role = send_content[i].role
      else
        table.remove(send_content, i)
      end
    end
  end

  ---@type llm.server.RequestOpts
  local opts = self
    .server--[[@as llm.OpenAIServer]]
    :build_request_opts(send_content, { stream = true })

  -- stylua: ignore start
  opts.callback = function() self:on_exit() end
  opts.stream = function(err, data) self:on_stream(err, data) end
  opts.on_error = function(err) self:on_error(err) end
  -- stylua: ignore end

  -- If new message, write to buffer and set extmark BEFORE sending request
  -- This ensures extmark doesn't include assistant response content
  if is_new_message then
    local user_message_index = #self.session.content
    local start_line = vim.api.nvim_buf_line_count(self.win.wins.response.bufnr)
    if input_lines then
      -- clear input for new messages from input buffer
      vim.api.nvim_buf_set_lines(self.win.wins.input.bufnr, 0, -1, false, {})
      self:_write_lines_to_response(self:_build_input_render_style(input_lines))
    else
      -- retry: write from message content
      self:_write_lines_to_response(self:_build_input_render_style(vim.split(message.content, "\n")))
    end
    local end_line = vim.api.nvim_buf_line_count(self.win.wins.response.bufnr)
    -- Set extmark with highlight for this user message (end_row exclusive, so use end_line - 1 to exclude empty line)
    self:_set_user_message_extmark(start_line, end_line - 1, user_message_index)
  end

  -- send request (stream may start immediately)
  local job = self.server:request(opts)

  if job and job:is_active() then
    self.requesting = job
  end

  self:_after_begin()

  -- add reasoning message to session
  self.session:add_message(self.current_response_reasoning)
  -- add response message to session
  self.session:add_message(self.current_response)

  -- Direct retry: message and extmark already in buffer, do nothing
end

---@private
function Chat:_add_long_time_separator()
  self:_write_lines_to_response { "----" }
end

---@private
function Chat:_add_round_separator()
  self:_write_lines_to_response { "", "**response ended!**" }
end

---@private
function Chat:_refresh_response_cursor()
  if vim.api.nvim_win_is_valid(self.win.wins.response.winid) then
    local new_row, new_col = util.get_last_char_position(self.win.wins.response.bufnr)
    vim.api.nvim_win_set_cursor(self.win.wins.response.winid, { new_row, new_col })
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
---@param start_row integer 0-indexed
---@param end_row integer 0-indexed (exclusive)
---@param message_index integer index in session.content
function Chat:_set_user_message_extmark(start_row, end_row, message_index)
  hl.set_user_message_extmark(self.win.wins.response.bufnr, start_row, end_row, message_index)
end

---@private
function Chat:_update_thinking_head()
  local head_line = tonumber(self.start_think.payload)
  assert(head_line, "start_think.payload is nil or not a number")
  vim.api.nvim_buf_set_lines(
    self.win.wins.response.bufnr,
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
    vim.api.nvim_buf_line_count(self.win.wins.response.bufnr) == 1
    and vim.api.nvim_buf_get_lines(self.win.wins.response.bufnr, 0, 1, false)[1] == ""
  then
    vim.api.nvim_buf_set_lines(self.win.wins.response.bufnr, 0, -1, false, lines)
  else
    vim.api.nvim_buf_set_lines(self.win.wins.response.bufnr, -1, -1, false, lines)
  end
  if add_margin_bottom == nil or add_margin_bottom then
    -- add empty line
    vim.api.nvim_buf_set_lines(self.win.wins.response.bufnr, -1, -1, false, { "" })
  end
  self:_refresh_response_cursor()
end

---@private
---@param content string
function Chat:_write_reason_text_to_response(content)
  local bufnr = self.win.wins.response.bufnr
  local row, col = util.get_last_char_position(bufnr)
  -- thinking content style
  content = content:gsub("\n", "\n> ")
  -- thinking head style
  if self.start_think.value then
    content = "\n> [!Tip] Thinking\n> " .. content
    self.start_think.value = false
    -- save thinking head line
    self.start_think.payload = row
  end
  local lines = vim.split(content, "\n")
  vim.api.nvim_buf_set_text(bufnr, row - 1, col, row - 1, col, lines)
  self:_refresh_response_cursor()
end

---@private
---@param content string
function Chat:_write_answer_text_to_response(content)
  if self.start_answer then
    -- new line
    content = (self.start_think.value and "\n" or "\n\n") .. content
    self.start_answer = false
  end
  local bufnr = self.win.wins.response.bufnr
  local row, col = util.get_last_char_position(bufnr)
  local lines = vim.split(content, "\n")
  vim.api.nvim_buf_set_text(bufnr, row - 1, col, row - 1, col, lines)
  self:_refresh_response_cursor()
end

---handle response(stream mode)
---@private
---@param res string
function Chat:_response_handler(res)
  if not res or res == "" then
    return
  end

  local chunk = self.server:handle_stream_chunk(res, self)

  -- not match normal response
  if chunk == nil then
    self:parse_error(res)
    return
  end

  -- response end
  if chunk == "[DONE]" or chunk == "[IGNORE]" then
    return
  end

  if type(chunk) == "string" then
    self:parse_error(chunk)
    return
  end

  -- handle chunk
  if type(chunk) == "table" then
    if chunk.reasoning_content then
      -- update reasoning message
      self.current_response_reasoning.role = chunk.role or self.current_response_reasoning.role
      self.current_response_reasoning.reasoning_content = self.current_response_reasoning.reasoning_content
        .. chunk.reasoning_content
      -- write reasoning content to response buf
      self:_write_reason_text_to_response(chunk.reasoning_content)
    else
      if self.start_think.payload then
        self:_update_thinking_head()
        self.start_think.payload = nil
      end
      -- update response message
      self.current_response.role = chunk.role or self.current_response.role
      self.current_response.content = self.current_response.content .. chunk.content
      -- write response content to response buf
      self:_write_answer_text_to_response(chunk.content)
    end
  end
end

---@private
function Chat:_clean_current_request_turn()
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

  -- smart naming trigger
  self:_maybe_generate_title()

  -- auto save
  self.session:save()
end

---@private
function Chat:_maybe_generate_title()
  -- 1. Check if title has been manually changed (not default id)
  if self.session.title ~= self.session.id then
    return
  end

  -- 2. Check if first round completed (exactly 2 messages: user + AI)
  if #self.session.content ~= 2 then
    return
  end

  -- 3. Check message structure
  local first_msg = self.session.content[1]
  local second_msg = self.session.content[2]
  if first_msg.role ~= (self.server.user_role or "user") then
    return
  end
  if second_msg.role == (self.server.user_role or "user") then
    return
  end

  -- 4. Check message length threshold and smart naming enabled
  local naming_config = config.options.smart_naming

  local msg_length = vim.fn.strchars(first_msg.content)

  local smart_naming_enabled = naming_config.enabled

  if msg_length < naming_config.min_length or not smart_naming_enabled then
    -- Use first max_length chars as title (fallback)
    local fallback_title = first_msg.content:sub(1, naming_config.max_length)
    -- Remove newlines and extra spaces
    fallback_title = fallback_title:gsub("%s+", " "):gsub("^%s*(.-)%s*$", "%1")
    if #fallback_title > 0 then
      self.session.title = fallback_title
      self.session:save { silent = true }
    end
    return
  end

  -- 5. Use AI generation for long messages with smart naming enabled
  self:_generate_title_async(first_msg.content)
end

---@private
---@return boolean
function Chat:_is_first_round_after_fork()
  if not self.session.forked_from then
    return false
  end
  return #self.session.content == self.session.inherited_count + 2
end

---@private
---@param first_message string
function Chat:_generate_title_async(first_message)
  local naming_config = config.options.smart_naming

  local messages = {
    {
      role = "user",
      content = string.format(naming_config.prompt, naming_config.max_length, first_message),
    },
  }

  -- Use specified light model or fallback to main server
  local title_server
  if naming_config.model then
    local server_key = naming_config.model
    title_server = ServerManager.servers[server_key]
  end
  title_server = title_server or self.server --[[@as llm.OpenAIServer]]

  -- Build request using server:request for unified handling
  local opts = title_server:build_request_opts(messages, { stream = false, temperature = 0.4, max_tokens = 100 })

  opts.callback = function(data)
    self.session._title_generation_job = nil
    if data.status ~= 200 then
      return
    end

    local title = title_server:parse_direct_result(data)
    if title then
      self.session.title = title
      self.session:save { silent = true }
    end
  end

  -- Send request via unified request method
  self.session._title_generation_job = title_server:request(opts)
end

---@private
function Chat:_after_begin()
  self.spinner:start()
  -- self:_add_request_separator()
  self:_register_stop_and_save_keymap()
  if vim.api.nvim_win_is_valid(self.win.wins.response.winid) then
    vim.api.nvim_set_current_win(self.win.wins.response.winid)
  end
  if (os.difftime(os.time(), self.session.update_time)) > 60 * 60 then
    self:_add_long_time_separator()
  end
end

---@private
function Chat:_after_stop()
  self:_clean_current_request_turn()
  self.spinner:stop()
  self:_remove_stop_request_keymap()
  self:_register_submit_keymap()
  self:_close(false)
end

function Chat:_init_response_status()
  self.start_think = { value = true, payload = nil }
  self.start_answer = true
  self.think_tag = { is = false, end_think = false, payload = nil }
  self.no_first_res_in_turn = false

  -- construct response message and reasoning message
  self.current_response = { role = "assistant", content = "" }
  self.current_response_reasoning = { role = "assistant", reasoning_content = "" }
end

---@param error llm.server.Error
function Chat:on_error(error)
  local err = string.format("[!CAUTION] Error!\n%s", error.message)
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
function Chat:parse_error(error)
  -- Comment lines in event streams that begin with a colon
  if error:match "^:%s" then
    -- maybe keep alive message,just ignore
    return
  end
  ---@type llm.server.Error
  local err_obj = {
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
  self:on_error(err_obj)
end

---on stream response
---@param err string
---@param data string
function Chat:on_stream(err, data)
  -- handle error
  if err then
    self:on_error { message = err, stderr = "" }
    -- handle response data
  else
    self:_response_handler(data)
  end
end

function Chat:on_exit()
  self:_after_stop()
  self:_add_round_separator()
end

---@private
function Chat:_input_enter_handler()
  local input_lines = vim.api.nvim_buf_get_lines(self.win.wins.input.bufnr, 0, -1, false)
  if input_lines[1] == "" then
    return
  end

  ---construct input message
  ---@type llm.session.Message
  local input_message = { role = self.server.user_role or "user", content = table.concat(input_lines, "\n") }

  -- submit message
  self:_submit_message(input_message, true, input_lines)
end

return ChatManager
