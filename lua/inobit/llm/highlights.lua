local M = {}

local config = require "inobit.llm.config"

if type(config.options.question_hi) == "string" then
  vim.cmd("highlight! link InobitQuestion " .. config.options.question_hi)
else
  vim.api.nvim_set_hl(0, "InobitQuestion", config.options.question_hi --[[@as vim.api.keyset.highlight]])
end

local NAMESPACE = vim.api.nvim_create_namespace "inobit_llm_session"

M.NAMESPACE = NAMESPACE

---@param buf integer
---@param start_row integer 0-indexed
---@param end_row integer 0-indexed (exclusive)
---@param message_index integer index in session.content
function M.set_user_message_extmark(buf, start_row, end_row, message_index)
  vim.api.nvim_buf_set_extmark(buf, NAMESPACE, start_row, 0, {
    end_row = end_row,
    id = message_index,
    hl_group = "InobitQuestion",
    hl_eol = true,
  })
end

---@param buf integer
function M.clear_extmarks(buf)
  vim.api.nvim_buf_clear_namespace(buf, NAMESPACE, 0, -1)
end

return M
