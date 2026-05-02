local util = require "inobit.llm.util"
local config = require "inobit.llm.config"
local SessionManager = require "inobit.llm.session"
local ProviderManager = require "inobit.llm.provider"
local win = require "inobit.llm.ui"
local hl = require "inobit.llm.highlights"
local Block = require "inobit.llm.block"
local Turn = require "inobit.llm.turn"
local notify = require "inobit.llm.notify"
local Spinner = require("inobit.llm.spinner").WinSpinner
local log = require "inobit.llm.log"

local RETRY_NAMESPACE = hl.NAMESPACE
local RETRY_HINT_EXTMARK_ID = 999999999 -- special id for retry hint virtual text

-- Spinner delay constants
local SPINNER_DELAY_MS = 500 -- Wait 500ms before showing spinner

---@class llm.chat.ActiveChatBuffer
---@field input_bufnr? integer
---@field response_bufnr? integer

---@class llm.Chat
---@field win llm.win.BaseChatWin
---@field session llm.Session
---@field provider llm.Provider
---@field requesting? llm.RequestJob
---@field spinner llm.Spinner
---@field wait_timer? uv_timer_t  -- Timer for delayed spinner display
---@field current_turn? llm.Turn  -- Current Turn (state control center)
---@field multi_round boolean  -- Enable multi-round conversation
---@field user_role string     -- Role name for user messages
---@field show_reasoning boolean -- Show reasoning/thinking content
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
    self.last_used_chat.win:close()
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
      self.last_used_chat.win:close()
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
    chat.win:close()
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
        title = this.session.title,
        input_bufnr = this.win.wins.input.bufnr,
        response_bufnr = this.win.wins.response.bufnr,
      }
    else
      this.win = win.FloatChatWin:new {
        title = this.session.title,
        input_bufnr = this.win.wins.input.bufnr,
        response_bufnr = this.win.wins.response.bufnr,
      }
    end
    -- Preserve existing state fields
    this.multi_round = this.multi_round
    this.user_role = this.user_role
    this.show_reasoning = this.show_reasoning
  else
    this = setmetatable({}, Chat)
    this.session = exists_session
      or SessionManager:new_session(
        ProviderManager.scenario_providers[config.Scenario.CHAT].provider,
        ProviderManager.scenario_providers[config.Scenario.CHAT].model
      )
    -- Auto-resolve via __index metatable (format: "Provider@Model")
    this.provider = ProviderManager.resolved_providers[this.session.provider .. "@" .. this.session.model]

    -- Initialize chat state fields with defaults
    this.multi_round = true
    this.user_role = "user"
    this.show_reasoning = true

    -- Choose window type based on config
    local chat_layout = config.options.chat_layout
    if chat_layout == "vsplit" then
      this.win = win.SplitChatWin:new { title = this.session.title }
    else
      this.win = win.FloatChatWin:new { title = this.session.title }
    end
  end
  -- this.spinner = Spinner:new(this.win.wins.response, "dynamic")
  this.spinner = Spinner:new(this.win.wins.response, "dynamic")
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
  this:_register_status_keymaps()
  this:_update_status_line()
  return this
end

---@private
---@return integer
function Chat:_set_header()
  local headers = {
    string.format("- **session title**: %s", self.session.title),
    string.format("- **session id**: %s", self.session.id),
    string.format("- **create time**: %s", os.date("%Y-%m-%d %H:%M:%S", self.session.create_time)),
  }
  -- Use direct buffer set to avoid _write_lines_to_response adding extra empty line
  if vim.api.nvim_buf_get_lines(self.win.wins.response.bufnr, 0, 1, false)[1] ~= "" then
    vim.api.nvim_buf_set_lines(self.win.wins.response.bufnr, 0, 5, false, headers)
  else
    vim.api.nvim_buf_set_lines(self.win.wins.response.bufnr, 0, -1, false, headers)
  end
  return #headers
end

---Change the model for current chat in real-time
---@param provider_name string
---@param model_id string
function Chat:change_model(provider_name, model_id)
  -- Block if there's an ongoing request
  if self.requesting then
    notify.warn("Cannot change model during request", "Wait for the current request to complete")
    return
  end

  -- Update session provider/model
  self.session.provider = provider_name
  self.session.model = model_id

  -- Update resolved provider instance
  self.provider = ProviderManager.resolved_providers[provider_name .. "@" .. model_id]

  -- Update header in response buffer
  self:_set_header()

  -- Update status line
  self:_update_status_line()

  notify.info("Model changed", string.format("Switched to %s@%s", provider_name, model_id))
end

---@private
function Chat:_resume_session()
  vim.api.nvim_set_current_win(self.win.wins.response.winid)
  self:_render()

  -- If there's an active streaming request, don't clear buffer
  -- Just restore window state and let streaming continue
  if self.requesting and self.current_turn then
    -- Scroll to latest content and return
    self:scroll_to_bottom()
    vim.api.nvim_set_current_win(self.win.wins.input.winid)
    return
  end

  local head_len = self:_set_header()
  -- Clear everything after header
  vim.api.nvim_buf_set_lines(self.win.wins.response.bufnr, head_len, -1, false, {})
  -- Clear existing block extmarks
  Block.clear_blocks(self.win.wins.response.bufnr)
  -- Re-render all messages from session turns
  if not vim.tbl_isempty(self.session.turns) then
    for _, turn in ipairs(self.session.turns) do
      self:render_turn(turn)
    end
  end
  vim.api.nvim_set_current_win(self.win.wins.input.winid)
end

---Render a single turn to the response buffer (via Turn)
---Chat creates Turn, Turn controls Block rendering
---Turn uses its own state (self.user.content) for rendering
---@private
---@param session_turn llm.session.Turn
function Chat:render_turn(session_turn)
  local bufnr = self.win.wins.response.bufnr

  -- Create Turn instance from session data (Turn controls Block)
  local turn = Turn.Turn.from_session_turn(session_turn, bufnr, self.show_reasoning)

  -- Turn renders all blocks using its own state
  turn:render_static()
end

---stop request (only kill job, state transition handled by process callback)
---@param should_cancel boolean if true, cancel the job; if false, just clear the reference
---@param reason? string cancel reason
function Chat:_close(should_cancel, reason)
  -- 1. Cancel request if needed (process callback will handle state transition)
  if self.requesting then
    if should_cancel then
      self.requesting:cancel(reason or "User canceled")
    end
    self.requesting = nil
  end

  -- 2. Stop spinner and wait timer
  self.spinner:stop()
  self:_stop_wait_timer()

  -- Save session (current_turn state will be updated by cancel callback)
  self:_save_session()
end

function Chat:_render()
  local status, module = pcall(require, "render-markdown")
  if status then
    module.buf_enable()
  end
end

---@private
---use <C-C> to cancel request
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
      -- Check if current session has turns
      if #self.session.turns > 0 then
        self:_prompt_fork_or_new()
      else
        -- Empty session, create new one directly
        ChatManager:new(
          SessionManager:new_session(
            ProviderManager.scenario_providers[config.Scenario.CHAT].provider,
            ProviderManager.scenario_providers[config.Scenario.CHAT].model
          )
        )
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

  win.PickerWin:new {
    title = "Continue based on existing session?",
    size = "small",
    items = choices,
    on_select = function(choice)
      if not choice then
        return
      end

      local new_session
      local total_rounds = #self.session.turns
      if choice:match "^n" then
        -- New session
        new_session = SessionManager:new_session(
          ProviderManager.scenario_providers[config.Scenario.CHAT].provider,
          ProviderManager.scenario_providers[config.Scenario.CHAT].model
        )
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
    end,
  }
end

---@private
function Chat:_prompt_custom_fork_range()
  local total_rounds = #self.session.turns

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

    start_round = tonumber(start_round) --[[@as number]]
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

    -- Use round numbers directly as turn indices (turns are rounds)
    local new_session = SessionManager:fork_session(self.session, { start = start_round, ["end"] = end_round })
    if new_session then
      ChatManager:new(new_session)
    end
  end)
end

---@private
---@param direction "next" | "prev"
function Chat:_navigate_to_question(direction)
  Block.navigate_to_block(
    self.win.wins.response.bufnr,
    self.win.wins.response.winid,
    direction,
    Block.BlockType.QUESTION
  )
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
    self:retry_at_cursor()
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

  -- Check if cursor is on a question block using extmarks
  local block = Block.get_question_at_cursor(bufnr, self.win.wins.response.winid)

  -- Clear existing hint first
  self:_remove_retry_hint()

  if block then
    -- Show hint at the end of current line
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
---Build messages for multi-round conversation
---Converts session turns to API format with proper role/content structure
---@return table[] Array of {role, content} tables for API request
function Chat:_build_multi_round_messages()
  return self.session:to_messages()
end

---@private
---@param session_turn llm.session.Turn
---@return table[]
function Chat:_build_send_content(session_turn)
  if self.multi_round then
    local content = self:_build_multi_round_messages()
    table.insert(content, { role = session_turn.user.role, content = session_turn.user.content })
    return content
  else
    return { { role = session_turn.user.role, content = session_turn.user.content } }
  end
end

---@private
---@param message llm.session.Message
function Chat:_submit_message(message)
  -- 1. Create SessionTurn (writes to session)
  local session_turn = self.session:new_turn(message)

  -- 2. Clear input buffer
  vim.api.nvim_buf_set_lines(self.win.wins.input.bufnr, 0, -1, false, {})

  -- 3. Start turn (unified entry point)
  self:start_turn(session_turn)
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
---@param lines string[]
---@param add_margin_bottom? boolean default false
function Chat:_write_lines_to_response(lines, add_margin_bottom)
  if
    vim.api.nvim_buf_line_count(self.win.wins.response.bufnr) == 1
    and vim.api.nvim_buf_get_lines(self.win.wins.response.bufnr, 0, 1, false)[1] == ""
  then
    vim.api.nvim_buf_set_lines(self.win.wins.response.bufnr, 0, -1, false, lines)
  else
    vim.api.nvim_buf_set_lines(self.win.wins.response.bufnr, -1, -1, false, lines)
  end
  if add_margin_bottom then
    -- add empty line after content (only used for non-block content like status messages)
    vim.api.nvim_buf_set_lines(self.win.wins.response.bufnr, -1, -1, false, { "" })
  end
  self:_refresh_response_cursor()
end

---handle response(stream mode)
---@private
---@param res string
function Chat:_response_handler(res)
  if not res or res == "" then
    return
  end

  local turn = self.current_turn
  if not turn then
    log.warn "No current turn in _response_handler"
    return
  end

  -- Parse stream chunk using Provider API
  local ok, chunk = self.provider:parse_stream_chunk(res)

  if not ok then
    -- Parse error
    self:on_error { message = chunk and chunk.error or "unknown parse error" }
    return
  end

  -- response end (nil result means [DONE] or heart beat)
  if chunk == nil then
    return
  end

  -- Handle chunk
  if type(chunk) == "table" then
    -- Check for API error in chunk
    if chunk.error then
      self:on_error { message = chunk.error }
      return
    end

    -- Handle reasoning content - Turn controls Block
    if chunk.reasoning_content then
      -- Clean content (remove leading newlines)
      local content = chunk.reasoning_content:gsub("^\n+", "")
      if content ~= "" then
        -- Stop spinner and restart wait timer (data received)
        self.spinner:stop()
        self:_stop_wait_timer()

        turn:on_reasoning_chunk(content)

        self:_refresh_response_cursor()

        -- Restart wait timer for next chunk
        self:_start_wait_timer()
      end
    end

    -- Handle content - Turn controls Block
    if chunk.content then
      -- Clean content (remove leading newlines)
      local content = chunk.content:gsub("^\n+", "")
      if content ~= "" then
        -- Stop spinner and restart wait timer (data received)
        self.spinner:stop()
        self:_stop_wait_timer()

        turn:on_response_chunk(content)

        self:_refresh_response_cursor()

        -- Restart wait timer for next chunk
        self:_start_wait_timer()
      end
    end

    -- Record finish_reason if present
    if chunk.finish_reason then
      turn:set_finish_reason(chunk.finish_reason)
    end
  end
end

---@private
function Chat:_save_session()
  -- Smart title generation (first round only)
  self:_maybe_generate_title()

  -- Save to file
  self.session:save()
end

---@private
function Chat:_maybe_generate_title()
  -- 1. Check if title has been manually changed
  if self.session.title ~= SessionManager.DEFAULT_TITLE then
    return
  end

  -- 2. Check if first round completed
  local turns = self.session.turns
  if #turns ~= 1 then
    return
  end

  local first_turn = turns[1]
  if first_turn.status ~= Turn.TurnStatus.COMPLETE then
    return
  end

  -- 3. Check message structure
  local first_msg = first_turn.user
  local assistant_msg = first_turn.assistant
  if not first_msg or not assistant_msg then
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
      -- Update window title for fallback title
      self.win:update_title(fallback_title)
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
  -- After fork, if we have exactly (inherited_count + 1) turns, it's the first round after fork
  return #self.session.turns == self.session.inherited_count + 1
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

  -- Use specified light model or fallback to main provider
  local title_provider
  if naming_config.model then
    -- Auto-resolve via __index metatable (format: "Provider@Model")
    title_provider = ProviderManager.resolved_providers[naming_config.model]
  end
  title_provider = title_provider or self.provider

  -- Build request using provider:request for unified handling
  local body = title_provider:build_request_body(messages, { stream = false, temperature = 0.4, max_tokens = 100 })
  local opts = title_provider:build_request_opts(body)

  -- If opts is nil, API key was required but not provided
  if not opts then
    return
  end

  opts.callback = function(data)
    self.session._title_generation_job = nil
    if data.status ~= 200 then
      return
    end

    local success, result = title_provider:parse_response(data)
    if success and result.content then
      local title = result.content:gsub("^%s+", ""):gsub("%s+$", "") -- trim whitespace
      self.session.title = title
      self.session:save { silent = true }
      -- Update window title when session title is generated
      self.win:update_title(title)
      -- Update header to reflect new title
      self:_set_header()
    end
  end

  -- Send request via unified request method
  self.session._title_generation_job = title_provider:request(opts)
end

---Start wait timer for delayed spinner display
---@private
function Chat:_start_wait_timer()
  self:_stop_wait_timer() -- Stop any existing timer first

  self.wait_timer = vim.uv.new_timer()
  self.wait_timer:start(SPINNER_DELAY_MS, 0, function()
    vim.schedule(function()
      if self.requesting and self.requesting:is_active() then
        -- Still waiting for data, show spinner
        self.spinner:start()
      end
    end)
  end)
end

---Stop wait timer
---@private
function Chat:_stop_wait_timer()
  if self.wait_timer then
    self.wait_timer:stop()
    self.wait_timer:close()
    self.wait_timer = nil
  end
end

---@private
function Chat:_after_begin()
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
  self:_save_session()
  self.spinner:stop()
  self:_stop_wait_timer()
  self:_remove_stop_request_keymap()
  self:_register_submit_keymap()
  -- Clear requesting reference (no kill)
  self.requesting = nil
end

---@private
---@param error_message string
function Chat:_display_error(error_message)
  -- Turn handles error block
  if self.current_turn then
    self.current_turn:on_error(error_message)
  end
end

---@param error llm.provider.Error
function Chat:on_error(error)
  -- Stop spinner and wait timer
  self.spinner:stop()
  self:_stop_wait_timer()

  -- Turn handles error and syncs to session itself
  if self.current_turn then
    self.current_turn:on_error(error.message)
    self.current_turn = nil
  end

  self:_after_stop()
end

---on cancel (user pressed Ctrl-C)
---@param reason string
function Chat:on_cancel(reason)
  -- Stop spinner and wait timer
  self.spinner:stop()
  self:_stop_wait_timer()

  -- Turn handles cancel and syncs to session itself
  if self.current_turn then
    self.current_turn:on_cancel(reason)
    self.current_turn = nil
  end

  self:_after_stop()
end

---on stream response
---@param err string
---@param data string
function Chat:on_stream(err, data)
  if err then
    self:on_error { message = err }
  else
    self:_response_handler(data)
  end
end

function Chat:on_exit()
  -- Stop spinner and wait timer
  self.spinner:stop()
  self:_stop_wait_timer()

  -- Turn handles completion and syncs to session itself
  if self.current_turn then
    self.current_turn:on_complete()
    self.current_turn = nil
  end

  self:_after_stop()
end

---@private
function Chat:_input_enter_handler()
  local input_lines = vim.api.nvim_buf_get_lines(self.win.wins.input.bufnr, 0, -1, false)
  if input_lines[1] == "" then
    return
  end

  ---construct input message
  ---@type llm.session.Message
  local input_message = { role = self.user_role, content = table.concat(input_lines, "\n") }

  -- submit message
  self:_submit_message(input_message)
end

---@private
---@param turn_id integer
---@return integer?
function Chat:find_turn_index(turn_id)
  for i, turn in ipairs(self.session.turns) do
    if turn.id == turn_id then
      return i
    end
  end
  return nil
end

---@private
---@param turn_idx integer
function Chat:clear_turn_response(turn_idx)
  local turn = self.session.turns[turn_idx]
  if not turn then
    return
  end
  local bufnr = self.win.wins.response.bufnr

  -- Find question block for this turn
  local question_blocks = Block.get_question_blocks(bufnr)
  for _, q in ipairs(question_blocks) do
    if q.turn_id == turn.id then
      -- Clear everything after question block (buffer content)
      vim.api.nvim_buf_set_lines(bufnr, q.end_row + 1, -1, false, {})
      -- Clear block extmarks after question block
      Block.clear_blocks_after_row(bufnr, q.end_row + 1)
      break
    end
  end
end

---@private
function Chat:retry_at_cursor()
  -- Block retry if there's an ongoing request
  if self.requesting then
    notify.info "Cannot retry while a request is in progress"
    return
  end

  -- Get turn from cursor position using extmarks
  local bufnr = self.win.wins.response.bufnr
  local winid = self.win.wins.response.winid
  local block = Block.get_question_at_cursor(bufnr, winid)

  if not block then
    notify.warn "No user message found at cursor"
    return
  end

  local turn_id = block.turn_id
  local turn_idx = self:find_turn_index(turn_id)
  if not turn_idx then
    notify.warn "Turn not found"
    return
  end

  local turn = self.session.turns[turn_idx]

  -- Rule 1: Unfinished turns are ignored
  if turn.status == Turn.TurnStatus.PENDING or turn.status == Turn.TurnStatus.STREAMING then
    notify.info "Current turn is still in progress"
    return
  end

  local is_last = turn_idx == #self.session.turns

  if not is_last then
    -- Rule 2: Middle turn, copy user to form a new turn
    local new_turn = self.session:new_turn(vim.deepcopy(turn.user))
    self:start_turn(new_turn)
    self:scroll_to_bottom()
  else
    -- Last turn
    if turn.status == Turn.TurnStatus.COMPLETE then
      -- Rule 3: Success, copy user to form a new turn
      local new_turn = self.session:new_turn(vim.deepcopy(turn.user))
      self:start_turn(new_turn)
      self:scroll_to_bottom()
    elseif turn.status == Turn.TurnStatus.ERROR or turn.status == Turn.TurnStatus.CANCELLED then
      -- Rule 4: Failure or cancelled, reset in place and retry
      turn.status = Turn.TurnStatus.PENDING
      turn.message = nil
      turn.assistant = nil
      turn.reasoning = nil
      turn.finish_reason = nil
      turn.update_time = os.time()
      -- Clear blocks after current question
      Block.clear_blocks_after_row(bufnr, block.end_row + 1)
      -- Clear buffer content after question
      vim.api.nvim_buf_set_lines(bufnr, block.end_row + 1, -1, false, {})
      self:start_turn(turn, true) -- Skip user render for retry
    end
  end
end

---@private
---Build messages for multi-round conversation
---Converts session turns to API format with proper role/content structure
---@return table[] Array of {role, content} tables for API request
function Chat:_build_multi_round_messages()
  return self.session:to_messages()
end

---Start turn - unified entry point for sending request and starting streaming
---@param session_turn llm.session.Turn
---@param skip_user_render? boolean if true, skip rendering user message (for retry)
function Chat:start_turn(session_turn, skip_user_render)
  local bufnr = self.win.wins.response.bufnr

  -- 1. Create Turn instance (unified: from_session_turn handles both new and existing turns)
  self.current_turn = Turn.Turn.from_session_turn(session_turn, bufnr, self.show_reasoning)
  self.current_turn.status = Turn.TurnStatus.STREAMING

  -- 2. Provide spinner control interface to Turn
  self.current_turn._spinner_control = {
    stop = function()
      self.spinner:stop()
      self:_stop_wait_timer()
    end,
    restart = function()
      self:_start_wait_timer()
    end,
  }

  -- 3. Render question (skip for in-place retry)
  if not skip_user_render then
    self.current_turn:on_question()
  end

  -- 4. Build and send request
  local send_content = self:_build_send_content(session_turn)
  local body = self.provider:build_request_body(send_content, { stream = true })
  local opts = self.provider:build_request_opts(body)

  if not opts then
    self.current_turn:on_error "API key not provided"
    self.current_turn = nil
    return
  end

  -- stylua: ignore start
  opts.callback = function() self:on_exit() end
  opts.cancel = function(reason) self:on_cancel(reason) end
  opts.stream = function(err, data) self:on_stream(err, data) end
  opts.on_error = function(err) self:on_error(err) end
  -- stylua: ignore end

  -- 5. Send request
  local job = self.provider:request(opts)

  if job and job:is_active() then
    self.requesting = job
  end

  -- 6. Start UI and wait timer
  self:_after_begin()
  self:_start_wait_timer()
end

---@private
function Chat:scroll_to_bottom()
  if vim.api.nvim_win_is_valid(self.win.wins.response.winid) then
    local line_count = vim.api.nvim_buf_line_count(self.win.wins.response.bufnr)
    vim.api.nvim_win_set_cursor(self.win.wins.response.winid, { line_count, 0 })
  end
end

---@private
---Update the status line with current state
function Chat:_update_status_line()
  local multi_status = self.multi_round and "Multi:ON" or "Multi:OFF"
  local reason_status = self.show_reasoning and "Reason:ON" or "Reason:OFF"
  local content = string.format(
    " [%s@%s] [%s] [%s] [Role:%s]",
    self.session.provider,
    self.session.model,
    multi_status,
    reason_status,
    self.user_role
  )

  self.win:set_status_content(content)
end

---Toggle multi_round setting
function Chat:toggle_multi_round()
  self.multi_round = not self.multi_round
  self:_update_status_line()
  notify.info("Multi-round " .. (self.multi_round and "enabled" or "disabled"))
end

---Toggle show_reasoning setting
function Chat:toggle_show_reasoning()
  self.show_reasoning = not self.show_reasoning
  self:_update_status_line()
  notify.info("Show reasoning " .. (self.show_reasoning and "enabled" or "disabled"))
end

---@private
---Cycle through user roles: user -> assistant -> system -> user
function Chat:_cycle_user_role()
  local roles = { "user", "assistant", "system" }
  local current_index = 1
  for i, role in ipairs(roles) do
    if role == self.user_role then
      current_index = i
      break
    end
  end
  local next_index = current_index % #roles + 1
  self.user_role = roles[next_index]
  self:_update_status_line()
  notify.info("User role changed to: " .. self.user_role)
end

---@private
---Register keymaps for status toggling
function Chat:_register_status_keymaps()
  local bufnrs = { self.win.wins.input.bufnr, self.win.wins.response.bufnr }
  local keymaps = config.options.status_keymaps

  for _, bufnr in ipairs(bufnrs) do
    vim.keymap.set({ "n", "i" }, keymaps.toggle_multi_round, function()
      self:toggle_multi_round()
    end, { buffer = bufnr, noremap = true, silent = true, desc = "LLM: Toggle multi-round" })

    vim.keymap.set({ "n", "i" }, keymaps.toggle_show_reasoning, function()
      self:toggle_show_reasoning()
    end, { buffer = bufnr, noremap = true, silent = true, desc = "LLM: Toggle show reasoning" })

    vim.keymap.set({ "n", "i" }, keymaps.cycle_user_role, function()
      self:_cycle_user_role()
    end, { buffer = bufnr, noremap = true, silent = true, desc = "LLM: Cycle user role" })
  end
end

return ChatManager
