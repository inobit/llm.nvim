local M = {}

local SPINNER_NAMESPACE = vim.api.nvim_create_namespace "inobit_spinner"

---@class llm.Spinner
---@field frames string[]
---@field current_frame integer
---@field active boolean
---@field frequency? integer
---@field timer? uv_timer_t
local Spinner = {}
Spinner.__index = Spinner

---@alias llm.SpinnerPosition "top-left" | "top-right" | "bottom-left" | "bottom-right" | "dynamic"

---Anchor type for WinSpinner - only needs winid and bufnr
---@class llm.SpinnerAnchor
---@field winid integer
---@field bufnr integer

---@class llm.WinSpinner: llm.Spinner
---@field anchor llm.SpinnerAnchor
---@field position llm.SpinnerPosition
---@field float_winid? integer  -- For fixed positions (top-left, etc.)
---@field float_bufnr? integer
---@field extmark_id? integer              -- For dynamic position (extmark-based)
local WinSpinner = {}
WinSpinner.__index = WinSpinner
setmetatable(WinSpinner, Spinner)

---@class llm.TextSpinner: llm.Spinner
---@field anchor  {value: string | nil}
local TextSpinner = {}
TextSpinner.__index = TextSpinner
setmetatable(TextSpinner, Spinner)

---@param frames? string[]
---@param frequency? integer
function Spinner:_new(frames, frequency)
  local this = {}
  this.frames = frames or { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
  this.frequency = frequency or 100
  this.current_frame = 1
  this.active = false
  return this
end

---@param anchor llm.SpinnerAnchor
---@param position? llm.SpinnerPosition default "bottom-right"
---@param frames? string[]
---@param frequency? integer
function WinSpinner:new(anchor, position, frames, frequency)
  local this = Spinner:_new(frames, frequency)
  this.anchor = anchor
  this.position = position or "bottom-right"
  return setmetatable(this, WinSpinner)
end

---@param anchor {value: string | nil}
---@param frames? string[]
---@param frequency? integer
function TextSpinner:new(anchor, frames, frequency)
  local this = Spinner:_new(frames, frequency)
  this.anchor = anchor
  return setmetatable(this, TextSpinner)
end

function WinSpinner:_show_frame()
  self:_close_frame()

  if not self.anchor.winid or not vim.api.nvim_win_is_valid(self.anchor.winid) then
    self:stop()
    return
  end

  -- Ensure bufnr exists
  if not self.anchor.bufnr then
    self:stop()
    return
  end

  local display_text = self.frames[self.current_frame]

  if self.position == "dynamic" then
    -- Use extmark virt_text for dynamic position (follows content automatically)
    local buf_height = vim.api.nvim_buf_line_count(self.anchor.bufnr)

    -- Find last non-empty line in buffer
    local last_content_row = buf_height - 1
    local last_line = ""

    -- Search backwards for a non-empty line
    for i = buf_height - 1, 0, -1 do
      local line = vim.api.nvim_buf_get_lines(self.anchor.bufnr, i, i + 1, false)[1] or ""
      if line ~= "" then
        last_content_row = i
        last_line = line
        break
      end
    end

    -- Calculate column at end of line
    local col = #last_line

    -- Set extmark with virt_text at end of last content line
    -- Use a fixed extmark ID (1) for easy cleanup
    self.extmark_id = 1
    vim.api.nvim_buf_set_extmark(self.anchor.bufnr, SPINNER_NAMESPACE, last_content_row, col, {
      id = self.extmark_id,
      virt_text = { { display_text, "InobitSpinner" } },
      virt_text_pos = "eol", -- Display at end of line
      right_gravity = true, -- Move right when text is appended after
    })
  else
    -- Use floating window for fixed positions
    local width = vim.fn.strdisplaywidth(display_text)

    -- Calculate position based on anchor window and position option
    local win_width = vim.api.nvim_win_get_width(self.anchor.winid)
    local win_height = vim.api.nvim_win_get_height(self.anchor.winid)

    local row, col

    if self.position == "top-left" then
      row = 0
      col = 0
    elseif self.position == "top-right" then
      row = 0
      col = math.max(win_width - width - 1, 0)
    elseif self.position == "bottom-left" then
      row = win_height - 1
      col = 0
    else -- "bottom-right" (default)
      row = win_height - 1
      col = math.max(win_width - width - 1, 0)
    end

    -- Create buffer and window directly
    self.float_bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(self.float_bufnr, 0, -1, false, { display_text })

    self.float_winid = vim.api.nvim_open_win(self.float_bufnr, false, {
      relative = "win",
      win = self.anchor.winid,
      width = width,
      height = 1,
      row = row,
      col = col,
      style = "minimal",
      border = "none",
      focusable = false,
      zindex = 9999,
    })
    vim.api.nvim_set_option_value("winblend", 10, { win = self.float_winid })
  end
end

function WinSpinner:_close_frame()
  -- Clear extmark if using dynamic position
  if self.extmark_id and self.anchor.bufnr then
    pcall(vim.api.nvim_buf_del_extmark, self.anchor.bufnr, SPINNER_NAMESPACE, self.extmark_id)
    self.extmark_id = nil
  end

  -- Close floating window if using fixed position
  if self.float_winid then
    pcall(vim.api.nvim_win_close, self.float_winid, true)
    self.float_winid = nil
  end
  if self.float_bufnr then
    pcall(vim.api.nvim_buf_delete, self.float_bufnr, { force = true })
    self.float_bufnr = nil
  end
end

function TextSpinner:_show_frame()
  self.anchor.value = self.frames[self.current_frame]
end

function TextSpinner:_close_frame()
  self.anchor.value = nil
end

function Spinner:start()
  self.active = true
  self.current_frame = 1
  if self.timer then
    self.timer:stop()
    self.timer:close()
    self.timer = nil
  end
  self.timer = vim.uv.new_timer()
  self.timer:start(
    0,
    self.frequency,
    vim.schedule_wrap(function()
      if not self.active then
        return
      end
      self.current_frame = self.current_frame % #self.frames + 1
      self--[[@as llm.WinSpinner | llm.TextSpinner]]:_show_frame()
    end)
  )
end

function Spinner:stop()
  self.active = false
  if self.timer then
    self.timer:stop()
    self.timer:close()
    self.timer = nil
  end
  self--[[@as llm.WinSpinner | llm.TextSpinner]]:_close_frame()
end

M.WinSpinner = WinSpinner
M.TextSpinner = TextSpinner
return M
