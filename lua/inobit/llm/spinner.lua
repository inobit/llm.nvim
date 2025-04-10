local win = require "inobit.llm.win"

---learn from https://github.com/yetone/avante.nvim/blob/89a86f0fc197ec9ffb3663a499432f8df4e4b1e5/lua/avante/ui/prompt_input.lua
---@class llm.Spinner
---@field frames string[]
---@field current_frame integer
---@field active boolean
---@field relative_floating llm.win.FloatingWin
---@field loading? llm.win.FloatingWin
---@field timer? uv_timer_t
local Spinner = {}
Spinner.__index = Spinner

---@param relative_floating llm.win.FloatingWin
---@param frames? string[]
function Spinner:new(relative_floating, frames)
  local this = {}
  this.frames = frames or { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
  this.current_frame = 1
  this.active = false
  this.relative_floating = relative_floating
  return setmetatable(this, Spinner)
end

function Spinner:_show_frame()
  self:_close_frame()

  if not self.relative_floating.winid or not vim.api.nvim_win_is_valid(self.relative_floating.winid) then
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
    win = self.relative_floating.winid,
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

function Spinner:_close_frame()
  if self.loading then
    self.loading:close()
    pcall(vim.api.nvim_buf_delete, self.loading.bufnr, { force = true })
    self.loading = nil
  end
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
    100,
    vim.schedule_wrap(function()
      if not self.active then
        return
      end
      self.current_frame = self.current_frame % #self.frames + 1
      self:_show_frame()
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
  self:_close_frame()
end

return Spinner
