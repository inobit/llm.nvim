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

-- used for automatically determining if the translated language is English
---@param text string
---@param sample_size? integer
---@param threshold? number
---@return boolean
function M.is_english(text, sample_size, threshold)
  sample_size = sample_size or 500
  threshold = threshold or 0.8

  -- len for byte not char
  local len = #text
  if len == 0 then
    return true
  end

  local checked = 0
  local ascii_count = 0

  for i = 1, math.min(len, sample_size) do
    local byte = text:byte(i)
    if byte < 128 then -- 标准ASCII范围判断
      ascii_count = ascii_count + 1
    end
    checked = checked + 1
  end

  -- 计算ASCII字符占比
  return (ascii_count / checked) >= threshold
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

function M.get_visual_text()
  local mode = vim.api.nvim_get_mode().mode
  local opts = {}
  -- \22 is an escaped version of <c-v>
  if mode == "v" or mode == "V" or mode == "\22" then
    opts.type = mode
  end
  return table.concat(vim.fn.getregion(vim.fn.getpos "v", vim.fn.getpos ".", opts), "\n")
end

function M.get_inner_text()
  -- save current location
  local cursor_pos = vim.api.nvim_win_get_cursor(0)

  -- select under the cursor iw (inner word)
  vim.cmd "normal! yiw"

  -- retrieve the copied text
  local text = vim.fn.getreg '"'

  -- restore cursor position
  vim.api.nvim_win_set_cursor(0, cursor_pos)

  return text
end

function M.replace_visual_selection(text)
  text = vim.api.nvim_replace_termcodes(text:gsub("\n", "<CR>"), true, true, true)
  vim.cmd("normal! c" .. vim.fn.escape(text, "\\"))
end

function M.replace_inner_word(text)
  local cursor_pos = vim.api.nvim_win_get_cursor(0)

  vim.cmd("normal! ciw" .. vim.fn.escape(text, "\\"))

  -- restore cursor position
  vim.api.nvim_win_set_cursor(0, cursor_pos)
end

return M
