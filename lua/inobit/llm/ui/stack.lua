local M = {}

---@class llm.ui.WinStack
---@field _zindex integer
M.WinStack = {}

M.WinStack._zindex = 100

function M.WinStack:_zindex_increment()
  self._zindex = self._zindex + 1
end

---@type integer[]
M.WinStack.stack = {}

---@param winid integer
function M.WinStack:push(winid)
  table.insert(self.stack, winid)
end

---Focus on the top valid window in the stack
---Pops invalid windows until finding a valid one, or stack is empty
function M.WinStack:focus()
  -- Traverse from end (most recent) to beginning
  while #self.stack > 0 do
    local winid = self.stack[#self.stack]
    if vim.api.nvim_win_is_valid(winid) then
      vim.api.nvim_set_current_win(winid)
      return
    else
      -- Remove invalid entry
      table.remove(self.stack)
    end
  end
end

---@param winid integer
---@param skip_focus? boolean If true, just delete from stack without focusing
function M.WinStack:pop(winid, skip_focus)
  -- Find and remove the entry with matching winid
  for i = #self.stack, 1, -1 do
    if self.stack[i] == winid then
      table.remove(self.stack, i)
      break
    end
  end
  if not skip_focus then
    self:focus()
  end
end

-- Initialize with current window as base
M.WinStack:push(0)

return M
