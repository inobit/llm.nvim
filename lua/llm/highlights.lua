local M = {}

local config = require "llm.config"

vim.api.nvim_set_hl(0, "InobitQuestion", config.options.question_hi)

local NAMESPACE = vim.api.nvim_create_namespace "inobit_llm_session"

function M.set_lines_highlights(buf, start_row, end_row)
  vim.api.nvim_buf_set_extmark(buf, NAMESPACE, start_row, 0, {
    end_row = end_row,
    hl_group = "InobitQuestion",
  })
end

return M
