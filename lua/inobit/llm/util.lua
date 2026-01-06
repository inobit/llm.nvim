local M = {}

---@param bufnr integer
function M.get_last_char_position(bufnr)
  local last_line = vim.api.nvim_buf_line_count(bufnr)
  local last_line_content = vim.api.nvim_buf_get_lines(bufnr, last_line - 1, last_line, false)[1]
  local last_char_col = #last_line_content
  return last_line, last_char_col
end

---@param str any
---@param strict? boolean
---@return boolean
function M.empty_str(str, strict)
  if strict == nil then
    strict = true
  end
  local is_nil = str == vim.NIL or str == nil
  if strict then
    return is_nil or tostring(str):match "^%s*$" ~= nil
  else
    return is_nil
  end
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
    -- standard ASCII range check
    if byte < 128 then
      ascii_count = ascii_count + 1
    end
    checked = checked + 1
  end

  -- calculate the proportion of ASCII characters
  return (ascii_count / checked) >= threshold
end

---@deprecated
---@param length integer
---@return string
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

---@param ms integer
---@param fn fun(...)
---@return fun(...)
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

---@return string
function M.get_visual_text()
  local mode = vim.api.nvim_get_mode().mode
  local opts = {}
  -- \22 is an escaped version of <c-v>
  if mode == "v" or mode == "V" or mode == "\22" then
    opts.type = mode
  end
  return table.concat(vim.fn.getregion(vim.fn.getpos "v", vim.fn.getpos ".", opts), "\n")
end

---@return string
function M.get_inner_text()
  return vim.fn.expand "<cword>"
end

---@param text string
function M.replace_visual_selection(text)
  text = vim.api.nvim_replace_termcodes(text:gsub("\n", "<CR>"), true, true, true)
  vim.cmd("normal! c" .. vim.fn.escape(text, "\\"))
end

---@param text string
function M.replace_inner_word(text)
  local cursor_pos = vim.api.nvim_win_get_cursor(0)

  vim.cmd("normal! ciw" .. vim.fn.escape(text, "\\"))

  -- restore cursor position
  vim.api.nvim_win_set_cursor(0, cursor_pos)
end

math.randomseed(tonumber(tostring(os.time()):reverse():sub(1, 9)) --[[@as integer]])
local random = math.random
---uuid
---@return string
function M.uuid()
  local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
  local ans = string.gsub(template, "[xy]", function(c)
    local v = (c == "x") and random(0, 0xf) or random(8, 0xb)
    return string.format("%x", v)
  end)
  return ans
end

---@param input string
---@param data string[]
---@return string[]
function M.data_filter(input, data)
  if data then
    return vim.tbl_filter(function(line)
      line = line or ""
      return string.lower(line):find(string.lower(input)) ~= nil
    end, data)
  else
    return {}
  end
end

---@param bufnr integer
---@param winid integer
---@return string?
function M.get_current_line(bufnr, winid)
  local lines = vim.api.nvim_buf_get_lines(
    bufnr,
    vim.api.nvim_win_get_cursor(winid)[1] - 1,
    vim.api.nvim_win_get_cursor(winid)[1],
    false
  )
  if lines and lines[1] and lines[1] ~= "" then
    return lines[1]
  end
end

---simple variable converter
---@param s string
---@param m "camel" | "underline"
---@return string
function M.simpleVariableConverter(s, m)
  if not s:find "%s" then
    return s
  end
  if m == "camel" then
    local t = {}
    for w in s:gmatch "[^%s]+" do
      t[#t + 1] = #t < 1 and w:lower() or w:sub(1, 1):upper() .. w:sub(2):lower()
    end
    return table.concat(t)
  elseif m == "underline" then
    return s:gsub("%s+", "_"):lower()
  else
    return s
  end
end

return M
