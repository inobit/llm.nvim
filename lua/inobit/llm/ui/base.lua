local M = {}

local stack = require "inobit.llm.ui.stack"
local util = require "inobit.llm.util"

-- Export WinStack from stack.lua for backward compatibility
M.WinStack = stack.WinStack

---@class llm.ui.WinConfig: vim.api.keyset.win_config
---@field winblend? integer
---@field bufnr? integer

-- Base window class
---@class llm.ui.BaseWin
---@field bufnr integer
---@field winid integer
local BaseWin = {}
BaseWin.__index = BaseWin

function BaseWin:close()
  pcall(vim.api.nvim_win_close, self.winid, true)
end

function BaseWin:register_content_change()
  vim.api.nvim_buf_attach(self.bufnr, false, {
    on_lines = util.debounce(100, function()
      if vim.api.nvim_win_is_valid(self.winid) then
        local lines = vim.api.nvim_buf_line_count(self.bufnr)
        if lines == 0 then
          vim.api.nvim_set_option_value("cursorline", false, { win = self.winid })
        elseif lines == 1 and vim.api.nvim_buf_get_lines(self.bufnr, 0, 1, true)[1] == "" then
          vim.api.nvim_set_option_value("cursorline", false, { win = self.winid })
        else
          vim.api.nvim_set_option_value("cursorline", true, { win = self.winid })
        end
      end
    end),
  })
end

---@class llm.ui.FloatingWin: llm.ui.BaseWin
---@field bufnr integer
---@field winid integer
M.FloatingWin = setmetatable({}, { __index = BaseWin })
M.FloatingWin.__index = M.FloatingWin

---@param opts llm.ui.WinConfig
---@return llm.ui.FloatingWin
function M.FloatingWin:new(opts)
  ---@type llm.ui.FloatingWin
  ---@diagnostic disable-next-line: missing-fields
  local this = {}
  local bufnr = opts.bufnr or vim.api.nvim_create_buf(false, true)
  local winblend = opts.winblend
  opts.winblend = nil
  opts.bufnr = nil
  local winid = vim.api.nvim_open_win(bufnr, false, opts)
  if winblend then
    vim.api.nvim_set_option_value("winblend", winblend, { win = winid })
  end
  this.bufnr = bufnr
  this.winid = winid
  return setmetatable(this, M.FloatingWin)
end

---@class llm.ui.SplitWin: llm.ui.BaseWin
---@field bufnr integer
---@field winid integer
M.SplitWin = setmetatable({}, { __index = BaseWin })
M.SplitWin.__index = M.SplitWin

---@param opts {bufnr?: integer, winid?: integer}
---@return llm.ui.SplitWin
function M.SplitWin:new(opts)
  local this = {}
  this.bufnr = opts.bufnr
  this.winid = opts.winid
  return setmetatable(this, M.SplitWin)
end

return M
