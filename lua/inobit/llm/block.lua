--- Block module - Passive UI layer for rendering content
--- Block lifecycle is completely controlled by Turn (begin/write/finish)
--- Block does not know about events or Turn state

local M = {}

local NAMESPACE = vim.api.nvim_create_namespace "inobit_blocks"
M.NAMESPACE = NAMESPACE

--------------------------------------------------------------------------------
-- Status Enums
--------------------------------------------------------------------------------

---@enum llm.BlockStatus
M.BlockStatus = {
  PENDING = "pending",
  STREAMING = "streaming",
  COMPLETE = "complete",
}

---@enum llm.BlockType
M.BlockType = {
  QUESTION = "question",
  THINKING = "thinking",
  REASONING = "reasoning",
  RESPONSE = "response",
  ERROR = "error",
  WARNING = "warning",
}

--------------------------------------------------------------------------------
-- Extmark ID Encoding Scheme
--------------------------------------------------------------------------------

-- Question: id = turn_id (1, 2, 3, ...)
-- Thinking: id = turn_id * 10000 + 0 (no persistent extmark, only animation)
-- Reasoning: id = turn_id * 10000 + 1
-- Response: id = turn_id * 10000 + 2
-- Error: id = turn_id * 10000 + 3
-- Warning: id = turn_id * 10000 + 4
-- Thinking animation: id = turn_id * 10000 + 200
-- Reasoning header: id = turn_id * 10000 + 100
-- Reasoning footer: id = turn_id * 10000 + 101
-- Error header: id = turn_id * 10000 + 102
-- Warning header: id = turn_id * 10000 + 103

local ID_OFFSET_THINKING = 0
local ID_OFFSET_REASONING = 1
local ID_OFFSET_RESPONSE = 2
local ID_OFFSET_ERROR = 3
local ID_OFFSET_WARNING = 4
local ID_OFFSET_THINKING_ANIMATION = 200
local ID_OFFSET_REASONING_HEADER = 100
local ID_OFFSET_REASONING_FOOTER = 101
local ID_OFFSET_ERROR_HEADER = 102
local ID_OFFSET_WARNING_HEADER = 103

--------------------------------------------------------------------------------
-- Utility Functions
--------------------------------------------------------------------------------

---Get highlight group for block type
---@param block_type llm.BlockType
---@return string
local function get_hl_group(block_type)
  local hl_map = {
    [M.BlockType.QUESTION] = "InobitQuestion",
    [M.BlockType.THINKING] = "InobitThinking",
    [M.BlockType.REASONING] = "InobitReasoning",
    [M.BlockType.RESPONSE] = "InobitResponse",
    [M.BlockType.ERROR] = "InobitError",
    [M.BlockType.WARNING] = "InobitWarning",
  }
  return hl_map[block_type] or "Normal"
end

---Build reasoning header line (80 chars total)
---@param icon string
---@param status "thinking"|"thought"
---@return string
local function build_reasoning_header(icon, status)
  local status_text = status == "thinking" and "Thinking..." or "Thought"
  local left = string.format("┌─ %s %s ─", icon, status_text)
  local fill_len = 80 - vim.fn.strwidth(left)
  if fill_len > 0 then
    return left .. string.rep("─", fill_len)
  end
  return left
end

--------------------------------------------------------------------------------
-- Block Base Class
--------------------------------------------------------------------------------

---@class llm.Block
---@field type llm.BlockType
---@field turn_id integer
---@field bufnr integer
---@field start_row integer  -- 0-indexed, set by begin()
---@field end_row integer    -- 0-indexed, set by finish()
---@field extmark_id integer -- set by finish()
---@field status llm.BlockStatus

local Block = {}
Block.__index = Block
M.Block = Block

---Create a new Block instance
---@param block_type llm.BlockType
---@param turn_id integer
---@param bufnr integer
---@return llm.Block
function Block:new(block_type, turn_id, bufnr)
  return setmetatable({
    type = block_type,
    turn_id = turn_id,
    bufnr = bufnr,
    status = M.BlockStatus.PENDING,
  }, self)
end

---Begin streaming block
---Record start_row, ensure separator, call subclass hook
function Block:begin()
  -- Ensure separator before block (UI layout responsibility)
  local line_count = vim.api.nvim_buf_line_count(self.bufnr)
  if line_count > 0 then
    local last_line = vim.api.nvim_buf_get_lines(self.bufnr, line_count - 1, line_count, false)[1] or ""
    if last_line ~= "" then
      vim.api.nvim_buf_set_lines(self.bufnr, -1, -1, false, { "" })
    end
  end

  self.start_row = vim.api.nvim_buf_line_count(self.bufnr)
  self.status = M.BlockStatus.STREAMING
  self:_on_begin() -- Hook for subclasses
end

---Write content to block (base implementation)
---Subclasses override to add type-specific styling
---@param content string|string[]
function Block:write(content)
  local lines = type(content) == "string" and vim.split(content, "\n") or content ---@cast lines string[]

  local line_count = vim.api.nvim_buf_line_count(self.bufnr)

  -- For streaming blocks (Response/Reasoning), append to last line instead of always adding new lines
  -- This handles chunk-by-chunk streaming properly
  if self.type == M.BlockType.RESPONSE or self.type == M.BlockType.REASONING then
    if line_count > 0 then
      local last_line = vim.api.nvim_buf_get_lines(self.bufnr, line_count - 1, line_count, false)[1] or ""

      if last_line ~= "" and lines[1] then
        -- Append first chunk to last line, then replace from last line position
        lines[1] = last_line .. lines[1]
        vim.api.nvim_buf_set_lines(self.bufnr, line_count - 1, -1, false, lines)
      elseif line_count == 1 and last_line == "" then
        -- Buffer is empty (just empty first line), replace with content
        vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines)
      elseif last_line == "" and lines[1] then
        -- Last line is empty separator (added by begin()), append content after it
        vim.api.nvim_buf_set_lines(self.bufnr, -1, -1, false, lines)
      else
        -- Fallback: append new content
        vim.api.nvim_buf_set_lines(self.bufnr, -1, -1, false, lines)
      end
    else
      vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines)
    end
  else
    -- Static mode (Question/Error): simple write
    if line_count == 1 and vim.api.nvim_buf_get_lines(self.bufnr, 0, 1, false)[1] == "" then
      vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines)
    else
      vim.api.nvim_buf_set_lines(self.bufnr, -1, -1, false, lines)
    end
  end

  -- Update cursor position
  self:_refresh_cursor()

  -- Hook for subclasses (e.g., real-time highlighting)
  self:_on_write()
end

---Finish block
---Record end_row, call subclass hook, set extmark
function Block:finish()
  self.status = M.BlockStatus.COMPLETE

  -- Hook for subclasses (e.g., clean trailing lines, add footer)
  self:_on_finish()

  -- Record end_row after subclass cleanup
  self.end_row = vim.api.nvim_buf_line_count(self.bufnr) - 1

  -- Set final extmark
  self:_set_extmark()
end

---Hook: called at begin (subclass override)
function Block:_on_begin() end

---Hook: called at write (subclass override)
function Block:_on_write() end

---Hook: called at finish (subclass override)
function Block:_on_finish() end

---Hook: clear additional extmarks associated with this block (subclass override)
---Base implementation does nothing (only main extmark)
---@param bufnr integer
---@param extmark_id integer
function Block:_clear_extmarks(bufnr, extmark_id) end

---Clear all extmarks associated with this block (public interface)
---Clears main extmark, then calls _clear_extmarks hook for additional cleanup
---@param bufnr integer
---@param extmark_id integer
function Block:clear_extmarks(bufnr, extmark_id)
  -- Clear main extmark
  vim.api.nvim_buf_del_extmark(bufnr, NAMESPACE, extmark_id)
  -- Call subclass hook for additional extmarks
  self:_clear_extmarks(bufnr, extmark_id)
end

---Set extmark with highlight (base implementation)
---Subclasses may override for special decorations
function Block:_set_extmark()
  local hl_group = get_hl_group(self.type)
  local id = self:_get_extmark_id()

  vim.api.nvim_buf_set_extmark(self.bufnr, NAMESPACE, self.start_row, 0, {
    id = id,
    end_row = self.end_row + 1,
    end_col = 0,
    hl_group = hl_group,
    hl_eol = true,
  })

  self.extmark_id = id
end

---Get extmark ID based on type and turn_id
---@return integer
function Block:_get_extmark_id()
  if self.type == M.BlockType.QUESTION then
    return self.turn_id
  elseif self.type == M.BlockType.THINKING then
    return self.turn_id * 10000 + ID_OFFSET_THINKING
  elseif self.type == M.BlockType.REASONING then
    return self.turn_id * 10000 + ID_OFFSET_REASONING
  elseif self.type == M.BlockType.RESPONSE then
    return self.turn_id * 10000 + ID_OFFSET_RESPONSE
  elseif self.type == M.BlockType.ERROR then
    return self.turn_id * 10000 + ID_OFFSET_ERROR
  elseif self.type == M.BlockType.WARNING then
    return self.turn_id * 10000 + ID_OFFSET_WARNING
  end
  return 0
end

---Refresh cursor position to end of buffer
function Block:_refresh_cursor()
  -- Placeholder, can be overridden
end

--------------------------------------------------------------------------------
-- QuestionBlock Subclass
--------------------------------------------------------------------------------

---@class llm.QuestionBlock: llm.Block
local QuestionBlock = {}
QuestionBlock.__index = QuestionBlock
setmetatable(QuestionBlock, { __index = Block })
M.QuestionBlock = QuestionBlock

---Create QuestionBlock instance
---@param turn_id integer
---@param bufnr integer
---@return llm.QuestionBlock
function QuestionBlock:new(turn_id, bufnr)
  local instance = {
    type = M.BlockType.QUESTION,
    turn_id = turn_id,
    bufnr = bufnr,
    status = M.BlockStatus.PENDING,
  }
  return setmetatable(instance, self)
end

---Write content with user_prompt prefix styling
---@param content string|string[]
function QuestionBlock:write(content)
  local lines = type(content) == "string" and vim.split(content, "\n") or content ---@cast lines string[]

  -- Add user_prompt prefix to first line
  if lines[1] then
    local config = require "inobit.llm.config"
    local opts = config.options or {}
    local prefix = opts.user_prompt or "❯"
    lines[1] = prefix .. " " .. lines[1]
  end

  -- Write to buffer (call base class method for actual buffer write)
  if vim.api.nvim_buf_line_count(self.bufnr) == 1 and vim.api.nvim_buf_get_lines(self.bufnr, 0, 1, false)[1] == "" then
    vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines)
  else
    vim.api.nvim_buf_set_lines(self.bufnr, -1, -1, false, lines)
  end

  self:_refresh_cursor()
end

--------------------------------------------------------------------------------
-- ResponseBlock Subclass
--------------------------------------------------------------------------------

---@class llm.ResponseBlock: llm.Block
local ResponseBlock = {}
ResponseBlock.__index = ResponseBlock
setmetatable(ResponseBlock, { __index = Block })
M.ResponseBlock = ResponseBlock

---Create ResponseBlock instance
---@param turn_id integer
---@param bufnr integer
---@return llm.ResponseBlock
function ResponseBlock:new(turn_id, bufnr)
  local instance = {
    type = M.BlockType.RESPONSE,
    turn_id = turn_id,
    bufnr = bufnr,
    status = M.BlockStatus.PENDING,
  }
  return setmetatable(instance, self)
end

---Hook: clean trailing empty lines at finish
function ResponseBlock:_on_finish()
  -- Clean trailing empty lines in buffer (caused by trailing \n in streaming content)
  local line_count = vim.api.nvim_buf_line_count(self.bufnr)
  while line_count > self.start_row do
    local last_line = vim.api.nvim_buf_get_lines(self.bufnr, line_count - 1, line_count, false)[1] or ""
    if last_line == "" then
      vim.api.nvim_buf_set_lines(self.bufnr, line_count - 1, line_count, false, {})
      line_count = line_count - 1
    else
      break
    end
  end
end

--------------------------------------------------------------------------------
-- ThinkingBlock Subclass
--------------------------------------------------------------------------------

---ThinkingBlock: Temporary UI indicator with animation
---Shows "Thinking..." animation while reasoning is streaming (when show_reasoning=false)
---Does not store any content, completely removed after finish

---@class llm.ThinkingBlock: llm.Block
---@field _timer? uv_timer_t Animation timer
---@field _frame integer Current animation frame
---@field _animation_extmark_id integer Animation extmark ID
---@field _spinner_control? { stop: function, restart: function } Spinner control interface from Chat
local ThinkingBlock = {}
ThinkingBlock.__index = ThinkingBlock
setmetatable(ThinkingBlock, { __index = Block })
M.ThinkingBlock = ThinkingBlock

---Animation frames for "Thinking..." indicator
local THINKING_FRAMES = { "Thinking.", "Thinking..", "Thinking..." }

---Create ThinkingBlock instance
---@param turn_id integer
---@param bufnr integer
---@param spinner_control? { stop: function, restart: function } Spinner control from Chat
---@return llm.ThinkingBlock
function ThinkingBlock:new(turn_id, bufnr, spinner_control)
  local instance = {
    type = M.BlockType.THINKING,
    turn_id = turn_id,
    bufnr = bufnr,
    status = M.BlockStatus.PENDING,
    _timer = nil,
    _frame = 1,
    _animation_extmark_id = turn_id * 10000 + ID_OFFSET_THINKING_ANIMATION,
    _spinner_control = spinner_control,
  }
  return setmetatable(instance, self)
end

---Hook: stop Chat spinner and start animation at begin
function ThinkingBlock:_on_begin()
  -- Stop Chat spinner mechanism when ThinkingBlock starts
  if self._spinner_control then
    self._spinner_control.stop()
  end
  if self.start_row > 0 then
    self:_start_animation()
  end
end

---Hook: restart Chat spinner and stop animation at finish
function ThinkingBlock:_on_finish()
  -- Restart Chat spinner mechanism when ThinkingBlock ends
  if self._spinner_control then
    self._spinner_control.restart()
  end
  self:_stop_animation()
end

---Set extmark: ThinkingBlock does not set persistent extmark (empty implementation)
function ThinkingBlock:_set_extmark()
  -- No extmark, block disappears completely after finish
  self.extmark_id = nil
end

---Write: ThinkingBlock does not write content (no-op)
---@param content string|string[]
function ThinkingBlock:write(content) end ---@diagnostic disable-line unused-local

---Start animation timer
function ThinkingBlock:_start_animation()
  self._timer = vim.uv.new_timer()
  self._timer:start(
    0,
    200,
    vim.schedule_wrap(function()
      if not vim.api.nvim_buf_is_valid(self.bufnr) then
        self:_stop_animation()
        return
      end
      -- Place animation extmark at start_row (same as ReasoningBlock header)
      vim.api.nvim_buf_set_extmark(self.bufnr, NAMESPACE, self.start_row, 0, {
        id = self._animation_extmark_id,
        virt_lines = { { { THINKING_FRAMES[self._frame], "InobitThinking" } } },
        virt_lines_above = true,
        right_gravity = false, -- Keep position fixed when content is added
      })
      self._frame = self._frame % #THINKING_FRAMES + 1
    end)
  )
end

---Stop animation timer and clear extmark
function ThinkingBlock:_stop_animation()
  if self._timer then
    self._timer:stop()
    self._timer:close()
    self._timer = nil
  end
  pcall(vim.api.nvim_buf_del_extmark, self.bufnr, NAMESPACE, self._animation_extmark_id)
end

---Hook: clear additional extmarks for thinking block (animation extmark)
---@param bufnr integer
---@param extmark_id integer
function ThinkingBlock:_clear_extmarks(bufnr, extmark_id)
  local turn_id = math.floor(extmark_id / 10000)
  -- Clear animation extmark
  pcall(vim.api.nvim_buf_del_extmark, bufnr, NAMESPACE, turn_id * 10000 + ID_OFFSET_THINKING_ANIMATION)
end

--------------------------------------------------------------------------------
-- ReasoningBlock Subclass
--------------------------------------------------------------------------------

---@class llm.ReasoningBlock: llm.Block
local ReasoningBlock = {}
ReasoningBlock.__index = ReasoningBlock
setmetatable(ReasoningBlock, { __index = Block })
M.ReasoningBlock = ReasoningBlock

---Create ReasoningBlock instance
---@param turn_id integer
---@param bufnr integer
---@return llm.ReasoningBlock
function ReasoningBlock:new(turn_id, bufnr)
  local instance = {
    type = M.BlockType.REASONING,
    turn_id = turn_id,
    bufnr = bufnr,
    status = M.BlockStatus.PENDING,
  }
  return setmetatable(instance, self)
end

---Hook: add header at begin
function ReasoningBlock:_on_begin()
  -- Add header with "thinking" status at separator row (start_row - 1)
  if self.start_row > 0 then
    self:_add_header "thinking"
  end
end

---Hook: real-time highlighting during write
function ReasoningBlock:_on_write()
  local current_end_row = vim.api.nvim_buf_line_count(self.bufnr) - 1
  if current_end_row >= self.start_row then
    vim.highlight.range(
      self.bufnr,
      NAMESPACE,
      "InobitReasoning",
      { self.start_row, 0 },
      { current_end_row, -1 },
      { inclusive = true }
    )
  end
end

---Hook: update header and add footer at finish
function ReasoningBlock:_on_finish()
  -- Clean trailing empty lines in buffer (caused by trailing \n in streaming content)
  -- Next block's begin() will add separator, not from content
  local line_count = vim.api.nvim_buf_line_count(self.bufnr)
  while line_count > self.start_row do
    local last_line = vim.api.nvim_buf_get_lines(self.bufnr, line_count - 1, line_count, false)[1] or ""
    if last_line == "" then
      vim.api.nvim_buf_set_lines(self.bufnr, line_count - 1, line_count, false, {})
      line_count = line_count - 1
    else
      break
    end
  end

  -- Clear temporary extmarks from vim.highlight.range
  self:_clear_temp_extmarks()

  -- Update header to "thought" status (at start_row)
  self:_update_header "thought"

  -- Add footer at end_row (reasoning content last line)
  self:_add_footer()
end

---Set extmark (no border, just highlight)
function ReasoningBlock:_set_extmark()
  local hl_group = get_hl_group(self.type)
  local id = self:_get_extmark_id()

  vim.api.nvim_buf_set_extmark(self.bufnr, NAMESPACE, self.start_row, 0, {
    id = id,
    end_row = self.end_row + 1,
    end_col = 0,
    hl_group = hl_group,
    hl_eol = true,
  })

  self.extmark_id = id
end

---Add reasoning header with status
---@param status "thinking"|"thought"
function ReasoningBlock:_add_header(status)
  local config = require "inobit.llm.config"
  local opts = config.options or {}
  local icon = opts.reasoning_icon or "💭"
  local header_text = build_reasoning_header(icon, status)
  local id = self.turn_id * 10000 + ID_OFFSET_REASONING_HEADER

  -- Header placed at start_row with virt_lines ABOVE the content
  -- Use right_gravity=false to keep extmark fixed when content is added after it
  vim.api.nvim_buf_set_extmark(self.bufnr, NAMESPACE, self.start_row, 0, {
    id = id,
    virt_lines = {
      { { header_text, "InobitReasoningHeader" } },
    },
    virt_lines_above = true,
    right_gravity = false,
  })
end

---Update reasoning header status
---@param status "thinking"|"thought"
function ReasoningBlock:_update_header(status)
  local config = require "inobit.llm.config"
  local opts = config.options or {}
  local icon = opts.reasoning_icon or "💭"
  local header_text = build_reasoning_header(icon, status)
  local id = self.turn_id * 10000 + ID_OFFSET_REASONING_HEADER

  local mark = vim.api.nvim_buf_get_extmark_by_id(self.bufnr, NAMESPACE, id, {})
  if mark and mark[1] then
    vim.api.nvim_buf_set_extmark(self.bufnr, NAMESPACE, mark[1], 0, {
      id = id,
      virt_lines = {
        { { header_text, "InobitReasoningHeader" } },
      },
      virt_lines_above = true,
    })
  end
end

---Add reasoning footer
function ReasoningBlock:_add_footer()
  local footer_text = "└" .. string.rep("─", 79)
  local id = self.turn_id * 10000 + ID_OFFSET_REASONING_FOOTER

  -- Use current last row (after cleaning trailing lines)
  local last_row = vim.api.nvim_buf_line_count(self.bufnr) - 1

  vim.api.nvim_buf_set_extmark(self.bufnr, NAMESPACE, last_row, 0, {
    id = id,
    virt_lines = {
      { { footer_text, "InobitReasoningHeader" } },
    },
  })
end

---Clear temporary extmarks created by vim.highlight.range
function ReasoningBlock:_clear_temp_extmarks()
  local marks = vim.api.nvim_buf_get_extmarks(self.bufnr, NAMESPACE, 0, -1, { details = true })
  for _, mark in ipairs(marks) do
    local extmark_id = mark[1]
    local mark_start_row = mark[2]
    -- Skip special extmarks (reasoning header/footer, retry hint)
    if
      extmark_id ~= 999999999
      and extmark_id ~= self.turn_id * 10000 + ID_OFFSET_REASONING_HEADER
      and extmark_id ~= self.turn_id * 10000 + ID_OFFSET_REASONING_FOOTER
      and mark_start_row >= self.start_row
    then
      vim.api.nvim_buf_del_extmark(self.bufnr, NAMESPACE, extmark_id)
    end
  end
end

---Hook: clear additional extmarks for reasoning block (header + footer)
---@param bufnr integer
---@param extmark_id integer
function ReasoningBlock:_clear_extmarks(bufnr, extmark_id)
  local turn_id = math.floor(extmark_id / 10000)
  -- Clear header
  vim.api.nvim_buf_del_extmark(bufnr, NAMESPACE, turn_id * 10000 + ID_OFFSET_REASONING_HEADER)
  -- Clear footer
  vim.api.nvim_buf_del_extmark(bufnr, NAMESPACE, turn_id * 10000 + ID_OFFSET_REASONING_FOOTER)
end

--------------------------------------------------------------------------------
-- ErrorBlock Subclass
--------------------------------------------------------------------------------

---@class llm.ErrorBlock: llm.Block
local ErrorBlock = {}
ErrorBlock.__index = ErrorBlock
setmetatable(ErrorBlock, { __index = Block })
M.ErrorBlock = ErrorBlock

---Create ErrorBlock instance
---@param turn_id integer
---@param bufnr integer
---@return llm.ErrorBlock
function ErrorBlock:new(turn_id, bufnr)
  local instance = {
    type = M.BlockType.ERROR,
    turn_id = turn_id,
    bufnr = bufnr,
    status = M.BlockStatus.PENDING,
  }
  return setmetatable(instance, self)
end

---Hook: add header at begin
function ErrorBlock:_on_begin()
  self:_add_header()
end

---Add error header (icon + "Error")
function ErrorBlock:_add_header()
  local header_text = "  Error"
  local id = self.turn_id * 10000 + ID_OFFSET_ERROR_HEADER

  vim.api.nvim_buf_set_extmark(self.bufnr, NAMESPACE, self.start_row, 0, {
    id = id,
    virt_lines = {
      { { header_text, "InobitError" } },
    },
    virt_lines_above = true,
    right_gravity = false,
  })
end

---Hook: clear additional extmarks for error block (header)
---@param bufnr integer
---@param extmark_id integer
function ErrorBlock:_clear_extmarks(bufnr, extmark_id)
  local turn_id = math.floor(extmark_id / 10000)
  -- Clear header
  vim.api.nvim_buf_del_extmark(bufnr, NAMESPACE, turn_id * 10000 + ID_OFFSET_ERROR_HEADER)
end

--------------------------------------------------------------------------------
-- WarningBlock Subclass
--------------------------------------------------------------------------------

---@class llm.WarningBlock: llm.Block
local WarningBlock = {}
WarningBlock.__index = WarningBlock
setmetatable(WarningBlock, { __index = Block })
M.WarningBlock = WarningBlock

---Create WarningBlock instance
---@param turn_id integer
---@param bufnr integer
---@return llm.WarningBlock
function WarningBlock:new(turn_id, bufnr)
  local instance = {
    type = M.BlockType.WARNING,
    turn_id = turn_id,
    bufnr = bufnr,
    status = M.BlockStatus.PENDING,
  }
  return setmetatable(instance, self)
end

---Hook: add header at begin
function WarningBlock:_on_begin()
  self:_add_header()
end

---Add warning header (icon + "Canceled")
function WarningBlock:_add_header()
  local header_text = "  Warning"
  local id = self.turn_id * 10000 + ID_OFFSET_WARNING_HEADER

  vim.api.nvim_buf_set_extmark(self.bufnr, NAMESPACE, self.start_row, 0, {
    id = id,
    virt_lines = {
      { { header_text, "InobitWarning" } },
    },
    virt_lines_above = true,
    right_gravity = false,
  })
end

---Hook: clear additional extmarks for warning block (header)
---@param bufnr integer
---@param extmark_id integer
function WarningBlock:_clear_extmarks(bufnr, extmark_id)
  local turn_id = math.floor(extmark_id / 10000)
  -- Clear header
  vim.api.nvim_buf_del_extmark(bufnr, NAMESPACE, turn_id * 10000 + ID_OFFSET_WARNING_HEADER)
end

--------------------------------------------------------------------------------
-- Navigation Functions (static, not part of Block class)
--------------------------------------------------------------------------------

---Get all block instances from buffer
---@param bufnr integer
---@return llm.Block[]
function M.get_blocks(bufnr)
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, NAMESPACE, 0, -1, { details = true })
  local blocks = {}

  for _, mark in ipairs(marks) do
    local extmark_id = mark[1]
    local start_row = mark[2]
    local details = mark[4]

    -- Skip retry hint extmark (special id) and non-block extmarks
    if extmark_id ~= 999999999 then
      ---@cast details -nil
      local hl_group = details.hl_group or ""
      local block_type = nil

      if hl_group == "InobitQuestion" then
        block_type = M.BlockType.QUESTION
      elseif hl_group == "InobitThinking" then
        block_type = M.BlockType.THINKING
      elseif hl_group == "InobitReasoning" then
        block_type = M.BlockType.REASONING
      elseif hl_group == "InobitResponse" then
        block_type = M.BlockType.RESPONSE
      elseif hl_group == "InobitError" then
        block_type = M.BlockType.ERROR
      elseif hl_group == "InobitWarning" then
        block_type = M.BlockType.WARNING
      end

      if block_type then
        local end_row = details.end_row and (details.end_row - 1) or start_row
        local turn_id

        if block_type == M.BlockType.QUESTION then
          turn_id = extmark_id
        else
          turn_id = math.floor(extmark_id / 10000)
        end

        -- Create Block instance based on type
        local block
        if block_type == M.BlockType.QUESTION then
          block = QuestionBlock:new(turn_id, bufnr)
        elseif block_type == M.BlockType.THINKING then
          block = ThinkingBlock:new(turn_id, bufnr)
        elseif block_type == M.BlockType.REASONING then
          block = ReasoningBlock:new(turn_id, bufnr)
        elseif block_type == M.BlockType.RESPONSE then
          block = ResponseBlock:new(turn_id, bufnr)
        elseif block_type == M.BlockType.ERROR then
          block = ErrorBlock:new(turn_id, bufnr)
        elseif block_type == M.BlockType.WARNING then
          block = WarningBlock:new(turn_id, bufnr)
        end

        -- Set position info from extmark
        block.start_row = start_row
        block.end_row = end_row
        block.extmark_id = extmark_id
        block.status = M.BlockStatus.COMPLETE

        table.insert(blocks, block)
      end
    end
  end

  -- Sort by start_row
  table.sort(blocks, function(a, b)
    return a.start_row < b.start_row
  end)

  return blocks
end

---Get question blocks only
---@param bufnr integer
---@return llm.QuestionBlock[]
function M.get_question_blocks(bufnr)
  local blocks = M.get_blocks(bufnr)
  return vim.tbl_filter(function(b)
    return b.type == M.BlockType.QUESTION
  end, blocks)
end

---Get block at cursor position
---@param bufnr integer
---@param winid integer
---@return llm.Block?
function M.get_block_at_cursor(bufnr, winid)
  if not vim.api.nvim_win_is_valid(winid) then
    return nil
  end

  local cursor_row = vim.api.nvim_win_get_cursor(winid)[1] - 1 -- 0-indexed

  local blocks = M.get_blocks(bufnr)
  for _, block in ipairs(blocks) do
    if cursor_row >= block.start_row and cursor_row <= block.end_row then
      return block
    end
  end

  return nil
end

---Get question block at cursor position
---@param bufnr integer
---@param winid integer
---@return llm.QuestionBlock?
function M.get_question_at_cursor(bufnr, winid)
  local block = M.get_block_at_cursor(bufnr, winid)
  if block and block.type == M.BlockType.QUESTION then
    return block
  end
  return nil
end

---Navigate to next/prev block of specified type
---@param bufnr integer
---@param winid integer
---@param direction "next"|"prev"
---@param block_type? llm.BlockType filter by type, nil for any block
function M.navigate_to_block(bufnr, winid, direction, block_type)
  if not vim.api.nvim_win_is_valid(winid) then
    return
  end

  local cursor_row = vim.api.nvim_win_get_cursor(winid)[1] - 1 -- 0-indexed
  local blocks = M.get_blocks(bufnr)

  if block_type then
    blocks = vim.tbl_filter(function(b)
      return b.type == block_type
    end, blocks)
  end

  if #blocks == 0 then
    return
  end

  local target_row = nil

  if direction == "next" then
    for _, block in ipairs(blocks) do
      if block.start_row > cursor_row then
        target_row = block.start_row + 1 -- 1-indexed for win_set_cursor
        break
      end
    end
    if not target_row then
      target_row = blocks[1].start_row + 1
    end
  else
    for i = #blocks, 1, -1 do
      local block = blocks[i]
      if block.start_row < cursor_row then
        target_row = block.start_row + 1
        break
      end
    end
    if not target_row then
      target_row = blocks[#blocks].start_row + 1
    end
  end

  if target_row then
    vim.api.nvim_win_set_cursor(winid, { target_row, 0 })
  end
end

---Clear all block extmarks from buffer
---@param bufnr integer
function M.clear_blocks(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, NAMESPACE, 0, -1)
end

---Clear block extmark by id
---@param bufnr integer
---@param extmark_id integer
function M.clear_block(bufnr, extmark_id)
  vim.api.nvim_buf_del_extmark(bufnr, NAMESPACE, extmark_id)
end

---Clear blocks after a specific row (for retry)
---@param bufnr integer
---@param start_row integer 0-indexed
function M.clear_blocks_after_row(bufnr, start_row)
  local blocks = M.get_blocks(bufnr)
  for _, block in ipairs(blocks) do
    if block.start_row >= start_row then
      block:clear_extmarks(bufnr, block.extmark_id)
    end
  end
end

return M
