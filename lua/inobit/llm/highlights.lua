local M = {}

-- Namespace for UI elements (retry hints, etc.)
-- Block highlighting uses blocks.lua namespace
local NAMESPACE = vim.api.nvim_create_namespace "inobit_llm_session"

M.NAMESPACE = NAMESPACE

---Get highlight configuration for inobit blocks
---@return table<string, string|vim.api.keyset.highlight>
function M.get_inobit_highlight_config()
  local config = require "inobit.llm.config"
  local opts = config.options or {}
  return {
    question = opts.question_hi or "Question",
    reasoning = opts.reasoning_hi or "Comment",
    thinking = opts.thinking_hi or "Comment",
    response = opts.response_hi or "Normal",
    error = opts.error_hi or "ErrorMsg",
    warning = opts.warning_hi or "WarningMsg",
    spinner = opts.spinner_hi or "Comment",
  }
end

---Setup inobit-specific highlights
---Defines highlight groups used by extmark-based block highlighting
---This is called from config.setup() after options are set
function M.setup_inobit_highlights()
  local hl_config = M.get_inobit_highlight_config()

  -- Question - user message (blue/purple theme)
  if type(hl_config.question) == "string" then
    vim.cmd("highlight! link InobitQuestion " .. hl_config.question)
  else
    vim.api.nvim_set_hl(0, "InobitQuestion", hl_config.question --[[@as vim.api.keyset.highlight]])
  end

  -- Reasoning - thinking process (dimmed/gray)
  if type(hl_config.reasoning) == "string" then
    vim.cmd("highlight! link InobitReasoning " .. hl_config.reasoning)
  else
    vim.api.nvim_set_hl(0, "InobitReasoning", hl_config.reasoning --[[@as vim.api.keyset.highlight]])
  end

  -- Reasoning header/border - same as reasoning, slightly bold
  vim.api.nvim_set_hl(0, "InobitReasoningHeader", { link = "InobitReasoning" })

  -- Thinking - temporary thinking indicator (same as reasoning by default)
  if type(hl_config.thinking) == "string" then
    vim.cmd("highlight! link InobitThinking " .. hl_config.thinking)
  else
    vim.api.nvim_set_hl(0, "InobitThinking", hl_config.thinking --[[@as vim.api.keyset.highlight]])
  end

  -- Response - normal content
  if type(hl_config.response) == "string" then
    vim.cmd("highlight! link InobitResponse " .. hl_config.response)
  else
    vim.api.nvim_set_hl(0, "InobitResponse", hl_config.response --[[@as vim.api.keyset.highlight]])
  end

  -- Error - error messages (red)
  if type(hl_config.error) == "string" then
    vim.cmd("highlight! link InobitError " .. hl_config.error)
  else
    vim.api.nvim_set_hl(0, "InobitError", hl_config.error --[[@as vim.api.keyset.highlight]])
  end

  -- Warning - warning/cancel messages (yellow/orange)
  if type(hl_config.warning) == "string" then
    vim.cmd("highlight! link InobitWarning " .. hl_config.warning)
  else
    vim.api.nvim_set_hl(0, "InobitWarning", hl_config.warning --[[@as vim.api.keyset.highlight]])
  end

  -- Spinner - loading animation (gray/comment)
  if type(hl_config.spinner) == "string" then
    vim.cmd("highlight! link InobitSpinner " .. hl_config.spinner)
  else
    vim.api.nvim_set_hl(0, "InobitSpinner", hl_config.spinner --[[@as vim.api.keyset.highlight]])
  end
end

return M
