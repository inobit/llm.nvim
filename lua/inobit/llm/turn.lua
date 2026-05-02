--- Turn module - State control center
--- Turn controls Block lifecycle completely (begin/write/finish)
--- Turn perceives current phase and drives Block changes
--- Single-direction data flow: Event → Turn state → Block

local M = {}

local Block = require "inobit.llm.block"
local QuestionBlock = Block.QuestionBlock
local ThinkingBlock = Block.ThinkingBlock
local ResponseBlock = Block.ResponseBlock
local ReasoningBlock = Block.ReasoningBlock
local ErrorBlock = Block.ErrorBlock
local WarningBlock = Block.WarningBlock

--------------------------------------------------------------------------------
-- Status Enums
--------------------------------------------------------------------------------

---@enum llm.TurnStatus
M.TurnStatus = {
  PENDING = "pending",
  STREAMING = "streaming",
  COMPLETE = "complete",
  ERROR = "error",
  CANCELLED = "cancelled",
}

---@enum llm.TurnPhase
M.TurnPhase = {
  QUESTION = "question",
  REASONING = "reasoning",
  RESPONSE = "response",
  ERROR = "error",
}

--------------------------------------------------------------------------------
-- Turn Class
--------------------------------------------------------------------------------

---@class llm.Turn
---@field id integer
---@field bufnr integer              -- Block rendering buffer
---@field show_reasoning boolean    -- Whether to display reasoning
---@field session_turn llm.session.Turn -- Reference to SessionTurn (sync target)
---@field current_phase? llm.TurnPhase -- Current data phase
---@field current_block? llm.Block   -- Current active Block
---@field blocks llm.Block[]         -- All blocks in this Turn
---@field user llm.session.Message           -- User message (input)
---@field assistant? llm.session.Message     -- AI response (output)
---@field reasoning? llm.session.Message     -- Reasoning/thinking content
---@field message? string            -- Turn message (error or cancel reason)
---@field finish_reason? string
---@field status llm.TurnStatus
---@field create_time integer
---@field update_time integer
---@field on_question fun(self: llm.Turn) -- Event: Question (uses self.user.content)
---@field on_reasoning_chunk fun(self: llm.Turn, content: string) -- Event: Reasoning chunk
---@field on_response_chunk fun(self: llm.Turn, content: string) -- Event: Response chunk
---@field on_complete fun(self: llm.Turn) -- Event: Turn complete
---@field on_error fun(self: llm.Turn, error_message: string) -- Event: Turn error
---@field on_cancel fun(self: llm.Turn, reason: string) -- Event: Turn cancel
---@field set_finish_reason fun(self: llm.Turn, reason: string) -- Set finish reason
---@field to_session_turn fun(self: llm.Turn): table -- Convert to session turn format
---@field render_static fun(self: llm.Turn) -- Render static content (uses self.user.content)

local Turn = {}
Turn.__index = Turn
M.Turn = Turn

---Create new Turn instance
---@param session_turn llm.session.Turn Reference to SessionTurn for syncing
---@param bufnr integer
---@param show_reasoning boolean
---@return llm.Turn
function Turn:new(session_turn, bufnr, show_reasoning)
  return setmetatable({
    id = session_turn.id,
    bufnr = bufnr,
    show_reasoning = show_reasoning,
    session_turn = session_turn,
    current_phase = nil,
    current_block = nil,
    blocks = {},
    user = session_turn.user,
    status = M.TurnStatus.PENDING,
    create_time = session_turn.create_time,
  }, self)
end

--------------------------------------------------------------------------------
-- Private Methods
--------------------------------------------------------------------------------

---Sync Turn data to SessionTurn
---@private
function Turn:_sync_to_session()
  if self.session_turn then
    self.session_turn:update(self:to_session_turn())
  end
end

---Clean trailing newlines from reasoning and assistant content
---Called before finishing turn to ensure clean content for next block's separator
---@private
function Turn:_clean_trailing_newlines()
  if self.reasoning and self.reasoning.reasoning_content then
    self.reasoning.reasoning_content = self.reasoning.reasoning_content:gsub("\n+$", "")
  end
  if self.assistant and self.assistant.content then
    self.assistant.content = self.assistant.content:gsub("\n+$", "")
  end
end

--------------------------------------------------------------------------------
-- Event Handlers - Turn controls Block lifecycle
--------------------------------------------------------------------------------

---Event: Question (user input)
---Turn creates and finishes Question Block
---Block handles separator and styling automatically
---Uses self.user.content (Turn already holds user message)
function Turn:on_question()
  self.status = M.TurnStatus.STREAMING
  self.current_phase = M.TurnPhase.QUESTION

  -- Create Question Block (handles separator and user_prompt styling)
  self.current_block = QuestionBlock:new(self.id, self.bufnr)
  self.current_block:begin()
  self.current_block:write(vim.split(self.user.content, "\n"))
  self.current_block:finish()

  -- Question is static, finish immediately
  self.blocks[#self.blocks + 1] = self.current_block
  self.current_block = nil

  -- Sync to session (user message ready)
  self:_sync_to_session()
end

---Event: Reasoning chunk arrived
---Turn perceives phase change and controls Block
---Block handles separator automatically
---@param content string
function Turn:on_reasoning_chunk(content)
  -- 1. Store data
  self:append_reasoning(content)

  -- 2. Perceive phase change → control Block lifecycle
  if self.current_phase ~= M.TurnPhase.REASONING then
    -- Phase transition: finish previous Block (if any)
    if self.current_block then
      self.current_block:finish()
      self.current_block = nil
    end

    -- Create Block based on show_reasoning setting
    if self.show_reasoning then
      -- Create Reasoning Block (Block handles separator in begin())
      self.current_block = ReasoningBlock:new(self.id, self.bufnr)
      self.current_block:begin()
    else
      -- Create Thinking Block (animation indicator, passes spinner_control for self-management)
      self.current_block = ThinkingBlock:new(self.id, self.bufnr, self._spinner_control)
      self.current_block:begin()
    end

    self.blocks[#self.blocks + 1] = self.current_block
    self.current_phase = M.TurnPhase.REASONING
  end

  -- 3. Update Block (only ReasoningBlock writes content, ThinkingBlock ignores)
  if self.show_reasoning and self.current_block then
    self.current_block:write(content)
  end
end

---Event: Response chunk arrived
---Turn perceives phase change and controls Block
---Block handles separator automatically
---@param content string
function Turn:on_response_chunk(content)
  -- 1. Store data
  self:append_response(content)

  -- 2. Perceive phase change → control Block lifecycle
  if self.current_phase ~= M.TurnPhase.RESPONSE then
    -- Phase transition: finish previous Block (reasoning/thinking → response)
    -- ThinkingBlock.finish() will restart spinner automatically
    if self.current_block then
      self.current_block:finish()
      self.current_block = nil
    end

    -- Create new Response Block (handles separator automatically)
    self.current_block = ResponseBlock:new(self.id, self.bufnr)
    self.current_block:begin()
    self.blocks[#self.blocks + 1] = self.current_block
    self.current_phase = M.TurnPhase.RESPONSE
  end

  -- 3. Update Block
  self.current_block:write(content)
end

---Event: Turn complete (successful finish)
---Turn finishes current Block and updates status
function Turn:on_complete()
  -- Clean trailing newlines from content (caused by model output)
  -- Separators should be added by next block's begin(), not from content
  self:_clean_trailing_newlines()

  -- Finish current Block (reasoning/thinking or response)
  -- ThinkingBlock.finish() restarts spinner automatically
  if self.current_block then
    self.current_block:finish()
    self.current_block = nil
  end

  -- Safety net: restart spinner if not already restarted by ThinkingBlock
  if self._spinner_control then
    self._spinner_control.restart()
  end

  -- Update status
  self.status = M.TurnStatus.COMPLETE
  self.current_phase = nil
  self.update_time = os.time()

  -- Sync to session (turn complete)
  self:_sync_to_session()
end

---Event: Turn error
---Turn finishes current Block, creates Error Block, updates status
---Block handles separator and header automatically
---@param error_message string
function Turn:on_error(error_message)
  -- 1. Finish current Block
  -- ThinkingBlock.finish() restarts spinner automatically
  if self.current_block then
    self.current_block:finish()
    self.current_block = nil
  end

  -- 2. Safety net: restart spinner if not already restarted
  if self._spinner_control then
    self._spinner_control.restart()
  end

  -- 3. Create Error Block (Block handles header via virt_lines_above)
  self.current_phase = M.TurnPhase.ERROR
  self.current_block = ErrorBlock:new(self.id, self.bufnr)
  self.current_block:begin()
  self.current_block:write { error_message }
  self.current_block:finish()
  self.blocks[#self.blocks + 1] = self.current_block
  self.current_block = nil

  -- 4. Update status
  self.message = error_message
  self.status = M.TurnStatus.ERROR
  self.current_phase = nil
  self.update_time = os.time()

  -- Sync to session (turn error)
  self:_sync_to_session()
end

---Event: Turn cancel (user interruption)
---Turn finishes current Block (preserving partial content), creates Warning Block, updates status
---Block handles separator and header automatically
---@param reason string
function Turn:on_cancel(reason)
  -- Clean trailing newlines from partial content
  self:_clean_trailing_newlines()

  -- Finish current Block (preserve partial content)
  if self.current_block then
    self.current_block:finish()
    self.current_block = nil
  end

  -- Ensure spinner is restarted
  if self._spinner_control then
    self._spinner_control.restart()
  end

  -- Create Warning Block (Block handles header via virt_lines_above)
  self.current_phase = M.TurnPhase.ERROR
  self.current_block = WarningBlock:new(self.id, self.bufnr)
  self.current_block:begin()
  self.current_block:write { reason }
  self.current_block:finish()
  self.blocks[#self.blocks + 1] = self.current_block
  self.current_block = nil

  -- Update status
  self.message = reason
  self.status = M.TurnStatus.CANCELLED
  self.current_phase = nil
  self.update_time = os.time()

  -- Sync to session (turn cancelled)
  self:_sync_to_session()
end

--------------------------------------------------------------------------------
-- Data Storage Methods
--------------------------------------------------------------------------------

---Append reasoning content
---@param content string
function Turn:append_reasoning(content)
  if not self.reasoning then
    self.reasoning = { role = "assistant", reasoning_content = "" }
  end
  self.reasoning.reasoning_content = self.reasoning.reasoning_content .. content
end

---Append response content
---@param content string
function Turn:append_response(content)
  if not self.assistant then
    self.assistant = { role = "assistant", content = "" }
  end
  self.assistant.content = self.assistant.content .. content
end

---Set finish reason
---@param reason string
function Turn:set_finish_reason(reason)
  self.finish_reason = reason
end

--------------------------------------------------------------------------------
-- Utility Methods
--------------------------------------------------------------------------------

---Check if Turn has any content
---@return boolean
function Turn:has_content()
  local has_reasoning = self.reasoning and self.reasoning.reasoning_content ~= ""
  local has_response = self.assistant and self.assistant.content ~= ""
  return has_reasoning or has_response
end

---Get all messages for API request
---@return table[]
function Turn:to_messages()
  local messages = {}
  -- User message
  table.insert(messages, { role = self.user.role, content = self.user.content })
  -- Assistant message (if exists)
  if self.assistant then
    table.insert(messages, { role = "assistant", content = self.assistant.content })
  end
  return messages
end

---Convert to session turn format (for persistence)
---@return table
function Turn:to_session_turn()
  return {
    id = self.id,
    user = self.user,
    assistant = self.assistant,
    reasoning = self.reasoning,
    message = self.message,
    finish_reason = self.finish_reason,
    status = self.status,
    create_time = self.create_time,
    update_time = self.update_time,
  }
end

---Render static content from completed session turn (for resume)
---This is called when restoring a session, not during streaming
---Block handles separator and styling automatically
---Uses self.user.content (Turn already holds user message)
function Turn:render_static()
  -- Helper: clean trailing newlines and split
  local function prepare_content(content)
    if not content then
      return {}
    end
    return vim.split(content:gsub("\n+$", ""), "\n")
  end

  -- 1. Question Block (always rendered)
  self.current_phase = M.TurnPhase.QUESTION
  self.current_block = QuestionBlock:new(self.id, self.bufnr)
  self.current_block:begin()
  self.current_block:write(prepare_content(self.user.content))
  self.current_block:finish()
  self.blocks[#self.blocks + 1] = self.current_block
  self.current_block = nil

  -- 2. Error Block (if error status)
  if self.status == M.TurnStatus.ERROR and self.message then
    self.current_phase = M.TurnPhase.ERROR
    self.current_block = ErrorBlock:new(self.id, self.bufnr)
    self.current_block:begin()
    self.current_block:write { self.message }
    self.current_block:finish()
    self.blocks[#self.blocks + 1] = self.current_block
    self.current_block = nil
    return
  end

  -- 3. Warning Block (if cancelled status)
  if self.status == M.TurnStatus.CANCELLED and self.message then
    self.current_phase = M.TurnPhase.ERROR
    self.current_block = WarningBlock:new(self.id, self.bufnr)
    self.current_block:begin()
    self.current_block:write { self.message }
    self.current_block:finish()
    self.blocks[#self.blocks + 1] = self.current_block
    self.current_block = nil
    return
  end

  -- 4. Reasoning Block (if complete and has reasoning)
  if
    self.status == M.TurnStatus.COMPLETE
    and self.reasoning
    and self.reasoning.reasoning_content
    and self.reasoning.reasoning_content ~= ""
  then
    if self.show_reasoning then
      self.current_phase = M.TurnPhase.REASONING
      self.current_block = ReasoningBlock:new(self.id, self.bufnr)
      self.current_block:begin()
      self.current_block:write(prepare_content(self.reasoning.reasoning_content))
      self.current_block:finish()
      self.blocks[#self.blocks + 1] = self.current_block
      self.current_block = nil
    end
  end

  -- 5. Response Block (if complete and has assistant content)
  if self.status == M.TurnStatus.COMPLETE and self.assistant and self.assistant.content then
    self.current_phase = M.TurnPhase.RESPONSE
    self.current_block = ResponseBlock:new(self.id, self.bufnr)
    self.current_block:begin()
    self.current_block:write(prepare_content(self.assistant.content))
    self.current_block:finish()
    self.blocks[#self.blocks + 1] = self.current_block
    self.current_block = nil
  end

  -- Clear phase after rendering
  self.current_phase = nil
end

---Restore from SessionTurn (for resume/retry)
---@param session_turn llm.session.Turn
---@param bufnr integer
---@param show_reasoning boolean
---@return llm.Turn
function Turn.from_session_turn(session_turn, bufnr, show_reasoning)
  local turn = Turn:new(session_turn, bufnr, show_reasoning)
  turn.assistant = session_turn.assistant
  turn.reasoning = session_turn.reasoning
  turn.message = session_turn.message
  turn.finish_reason = session_turn.finish_reason
  turn.status = session_turn.status
  turn.update_time = session_turn.update_time or os.time()
  return turn
end

return M
