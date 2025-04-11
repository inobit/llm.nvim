local win = require "inobit.llm.win"

---learn from https://github.com/yetone/avante.nvim/blob/89a86f0fc197ec9ffb3663a499432f8df4e4b1e5/lua/avante/ui/prompt_input.lua
---@class llm.Spinner
---@field frames string[]
---@field current_frame integer
---@field active boolean
---@field frequency? integer
---@field timer? uv_timer_t
local Spinner = {}
Spinner.__index = Spinner

---@class llm.FloatSpinner: llm.Spinner
---@field anchor llm.win.FloatingWin
---@field loading? llm.win.FloatingWin
local FloatSpinner = {}
FloatSpinner.__index = FloatSpinner
setmetatable(FloatSpinner, Spinner)

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

---@param anchor llm.win.FloatingWin
---@param frames? string[]
---@param frequency? integer
function FloatSpinner:new(anchor, frames, frequency)
  local this = Spinner:_new(frames, frequency)
  this.anchor = anchor
  return setmetatable(this, FloatSpinner)
end

---@param anchor {value: string | nil}
---@param frames? string[]
---@param frequency? integer
function TextSpinner:new(anchor, frames, frequency)
  local this = Spinner:_new(frames, frequency)
  this.anchor = anchor
  return setmetatable(this, TextSpinner)
end

function FloatSpinner:_show_frame()
  self:_close_frame()

  if not self.anchor.winid or not vim.api.nvim_win_is_valid(self.anchor.winid) then
    self:stop()
    return
  end

  --TODO: dynamic frame positioning in repsonse win

  -- local win_width = vim.api.nvim_win_get_width(self.relative_floating.winid)
  -- local win_height = vim.api.nvim_win_get_height(self.relative_floating.winid)
  -- local buf_height = vim.api.nvim_buf_line_count(self.relative_floating.bufnr)
  local display_text = self.frames[self.current_frame]
  local width = vim.fn.strdisplaywidth(display_text)
  ---@type llm.win.WinConfig
  local opts = {
    relative = "win",
    win = self.anchor.winid,
    width = width,
    height = 1,
    -- row = math.min(buf_height, win_height),
    -- col = math.max(win_width - width, 0),
    row = 0,
    col = 0,
    style = "minimal",
    border = "none",
    focusable = false,
    zindex = 9999,
    winblend = 10,
  }
  self.loading = win.FloatingWin:new(opts)
  vim.api.nvim_buf_set_lines(self.loading.bufnr, 0, -1, false, { display_text })
end

function FloatSpinner:_close_frame()
  if self.loading then
    self.loading:close()
    pcall(vim.api.nvim_buf_delete, self.loading.bufnr, { force = true })
    self.loading = nil
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
      self--[[@as llm.FloatSpinner | llm.TextSpinner]]:_show_frame()
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
  self--[[@as llm.FloatSpinner | llm.TextSpinner]]:_close_frame()
end

local M = {}
M.FloatSpinner = FloatSpinner
M.TextSpinner = TextSpinner
return M
