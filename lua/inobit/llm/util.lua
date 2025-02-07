local M = {}

function M.get_last_char_position(bufnr)
  local last_line = vim.api.nvim_buf_line_count(bufnr)
  local last_line_content = vim.api.nvim_buf_get_lines(bufnr, last_line - 1, last_line, false)[1]
  local last_char_col = #last_line_content
  return last_line - 1, last_char_col
end

function M.scroll_to_end(win, bufnr)
  local win_height = vim.api.nvim_win_get_height(win)
  local total_lines = vim.api.nvim_buf_line_count(bufnr)
  if total_lines > win_height then
    -- trigger scroll
    vim.api.nvim_win_set_cursor(win, { total_lines, 0 })
  end
end

function M.empty_str(str)
  return str == nil or str:match "^%s*$" ~= nil
end

-- Decoding UTF-8 Byte Sequences LuaJIT does not have a built-in UTF8 module.
function M.is_chinese(byte_sequence)
  if #byte_sequence ~= 3 then
    return false
  end
  local b1, b2, b3 = byte_sequence[1], byte_sequence[2], byte_sequence[3]
  -- Check if the first byte complies with the 3-byte UTF-8 encoding rules.
  if b1 < 0xE0 or b1 >= 0xF0 then
    return false
  end
  -- calculate unicode code point
  local code_point = ((b1 % 0x10) * 0x1000) + ((b2 % 0x40) * 0x40) + (b3 % 0x40)
  -- Determine whether it falls within the range of Chinese characters.
  return code_point >= 0x4E00 and code_point <= 0x9FFF
end

function M.is_legal_char(char)
  if char:len() == 1 then
    return string.match(char, "[%w-]")
  else
    local sequence = {}
    for i = 1, char:len() do
      table.insert(sequence, char:sub(i, i):byte())
    end
    return M.is_chinese(sequence)
  end
end

function M.generate_random_string(length)
  math.randomseed(os.time())
  local chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
  local result = {}
  for _ = 1, length do
    local rand_index = math.random(#chars)
    table.insert(result, chars:sub(rand_index, rand_index))
  end
  return table.concat(result)
end

function M.debounce(ms, fn)
  local timer = vim.uv.new_timer()
  return function(...)
    local argv = { ... }
    timer:start(ms, 0, function()
      timer:stop()
      vim.schedule_wrap(fn)(unpack(argv))
    end)
  end
end

function M.add_line_separator(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "", "" })
end

return M
