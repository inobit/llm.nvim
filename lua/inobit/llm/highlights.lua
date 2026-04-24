local M = {}

local config = require "inobit.llm.config"

local NAMESPACE = vim.api.nvim_create_namespace "inobit_llm_session"

M.NAMESPACE = NAMESPACE

---Setup highlight group based on configuration
---Supports:
--- - "GroupName" - link to another highlight group (e.g., "MoreMsg", "Question")
--- - { fg = ..., bg = ..., ... } - custom color table
function M.setup_highlight()
  local question_hi = config.options.question_hi

  if type(question_hi) == "string" then
    -- link to existing highlight group
    vim.cmd("highlight! link InobitQuestion " .. question_hi)
  else
    -- custom color table
    vim.api.nvim_set_hl(0, "InobitQuestion", question_hi --[[@as vim.api.keyset.highlight]])
  end
end

-- Initialize highlight on module load
M.setup_highlight()

---@param buf integer
---@param start_row integer 0-indexed
---@param end_row integer 0-indexed (empty line index, user message ends at end_row-1)
---@param message_index integer index in session.content
function M.set_user_message_extmark(buf, start_row, end_row, message_index)
  -- Extmark for retry detection: covers user message only (start_row to end_row-1)
  -- end_row is the empty line index, extmark's end_row is exclusive so actual range is [start_row, end_row-1]
  vim.api.nvim_buf_set_extmark(buf, NAMESPACE, start_row, 0, {
    end_row = end_row, -- exclusive: covers user message, excludes empty line
    id = message_index,
  })

  -- Highlight user message content only, exclude empty line
  -- end_row-1 is the actual last line of user message
  vim.highlight.range(buf, NAMESPACE, "InobitQuestion", { start_row, 0 }, { end_row - 1, -1 }, { inclusive = true })
end

---@param buf integer
function M.clear_extmarks(buf)
  vim.api.nvim_buf_clear_namespace(buf, NAMESPACE, 0, -1)
end

return M
