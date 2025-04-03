local M = {}

local config = require "inobit.llm.config"

if type(config.options.question_hi) == "string" then
  vim.cmd("highlight! link InobitQuestion " .. config.options.question_hi)
else
  vim.api.nvim_set_hl(0, "InobitQuestion", config.options.question_hi --[[@as vim.api.keyset.highlight]])
end

local NAMESPACE = vim.api.nvim_create_namespace "inobit_llm_session"

function M.set_lines_highlights(buf, start_row, end_row)
  vim.api.nvim_buf_set_extmark(buf, NAMESPACE, start_row, 0, {
    end_row = end_row,
    hl_group = "InobitQuestion",
  })
end

---@param buf integer
function M.mark_sections(buf)
  -- clear old markers
  vim.api.nvim_buf_clear_namespace(buf, NAMESPACE, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local start_line = nil

  for i, line in ipairs(lines) do
    local begin_line_pattern = "^" .. config.options.user_prompt
    if line:match(begin_line_pattern) then
      start_line = i - 1
    elseif start_line and (line:match "^%s*$" and (i - start_line) >= 2) then
      -- one empty lines detected at the end.
      local end_line = i - 1
      --add extmark and bind highlight
      vim.api.nvim_buf_set_extmark(buf, NAMESPACE, start_line, 0, {
        end_row = end_line,
        hl_group = "InobitQuestion",
        hl_eol = true,
      })
      start_line = nil
    end
  end
end

return M
