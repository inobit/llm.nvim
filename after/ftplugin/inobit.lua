-- Inobit filetype configuration
-- This file is loaded when a buffer has filetype "inobit"
-- Note: Highlight groups are defined in config.setup() via highlights.setup_inobit_highlights()
-- Note: Block highlighting is handled by blocks.lua using extmarks (no syntax markers)

-- Register markdown treesitter parser for render-markdown.nvim
-- render-markdown.nvim needs the parser for markdown rendering
local ok, ts = pcall(require, "nvim-treesitter.parsers")
if ok then
  vim.treesitter.language.register("markdown", "inobit")
end

-- Note: No conceal settings needed - block markers are not written to buffer
-- Note: No syntax file needed - extmarks handle all highlighting
