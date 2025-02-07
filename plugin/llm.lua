---@diagnostic disable: undefined-field
local mappings = {
  up = "<C-W>k",
  down = "<C-W>j",
  left = "<C-W>h",
  right = "<C-W>l",
}
local system_mappings = vim.api.nvim_get_keymap "n"
for _, item in ipairs(system_mappings) do
  if item.rhs == mappings.up then
    mappings.up = item.lhs
  end
  if item.rhs == mappings.down then
    mappings.down = item.lhs
  end
  if item.rhs == mappings.left then
    mappings.left = item.lhs
  end
  if item.rhs == mappings.right then
    mappings.right = item.lhs
  end
end
require("inobit.llm.config").install_win_cursor_move_keymap(mappings)
