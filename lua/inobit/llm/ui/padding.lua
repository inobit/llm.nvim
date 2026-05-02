local M = {}

local base = require "inobit.llm.ui.base"

-- Re-export from base
M.FloatingWin = base.FloatingWin

---@class llm.ui.PaddingFloatingWin: llm.ui.FloatingWin
---@field private background? llm.ui.FloatingWin
---@field body llm.ui.FloatingWin
M.PaddingFloatingWin = {}
M.PaddingFloatingWin.__index = function(table, key)
  if key == "bufnr" then
    return table.body.bufnr
  elseif key == "winid" then
    return table.body.winid
  else
    return M.PaddingFloatingWin[key]
  end
end
setmetatable(M.PaddingFloatingWin, M.FloatingWin)

---@alias llm.ui.Padding number | number[] top right bottom left

---@param opts llm.ui.WinConfig
---@param padding? llm.ui.Padding
---@return llm.ui.PaddingFloatingWin
function M.PaddingFloatingWin:new(opts, padding)
  local this = {}
  setmetatable(this, M.PaddingFloatingWin)

  local notify = require "inobit.llm.notify"
  local total_padding = 0
  if padding then
    if type(padding) == "number" then
      padding = { padding, padding, padding, padding }
    elseif type(padding) == "table" and not vim.tbl_isempty(padding) then
      if #padding == 1 then
        padding = { padding[1], padding[1], padding[1], padding[1] }
      elseif #padding == 2 then
        padding = { padding[1], padding[2], padding[1], padding[2] }
      elseif #padding == 3 then
        padding = { padding[1], padding[2], padding[3], padding[2] }
      else
        padding = { padding[1], padding[2], padding[3], padding[4] }
      end
    end
    for i, v in
      ipairs(padding --[=[@as number[] ]=])
    do
      if v < 0 then
        padding[i] = 0
        notify.warn "padding must be positive,has been processed to 0!"
      end
      total_padding = total_padding + v
    end
  end

  if total_padding == 0 then
    this.body = M.FloatingWin:new(opts)
    return this
  end

  local background_opts = opts
  local body_opts = vim.tbl_deep_extend("force", {}, opts)
  background_opts.bufnr = nil
  background_opts.focusable = false
  local background = M.FloatingWin:new(background_opts)
  vim.api.nvim_set_option_value("cursorline", false, { win = background.winid })

  local background_width = vim.api.nvim_win_get_width(background.winid)
  local background_height = vim.api.nvim_win_get_height(background.winid)

  body_opts.anchor = nil
  body_opts.title = nil
  body_opts.title_pos = nil
  body_opts.footer = nil
  body_opts.footer_pos = nil
  body_opts.fixed = nil
  body_opts.relative = "win"
  body_opts.win = background.winid
  body_opts.style = "minimal"
  body_opts.border = "none"

  local _padding = padding --[=[@as number[] ]=]
  body_opts.row = math.floor(_padding[1])
  body_opts.height = math.floor(background_height - _padding[1] - _padding[3])
  body_opts.col = math.floor(_padding[4])
  body_opts.width = math.floor(background_width - _padding[4] - _padding[2])

  this.body = M.FloatingWin:new(body_opts)
  this.background = background

  return this
end

function M.PaddingFloatingWin:close()
  if self.background then
    pcall(vim.api.nvim_win_close, self.background.winid, true)
    pcall(vim.api.nvim_buf_delete, self.background.bufnr, { force = true })
  end
  pcall(vim.api.nvim_win_close, self.body.winid, true)
end

return M
