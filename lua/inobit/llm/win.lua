local M = {}
local config = require "inobit.llm.config"
local util = require "inobit.llm.util"

--TODO: refactor through metatable/prototype

-- floating windows from-stack
local floating_win_stack = {}

function M.create_floating_window(width, height, row, col, winblend, title)
  local bufnr = vim.api.nvim_create_buf(false, true)
  local win_id = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "center",
    focusable = true,
  })
  vim.api.nvim_set_option_value("winblend", winblend, { win = win_id })
  -- vim.cmd(
  --   string.format(
  --     "autocmd WinClosed <buffer> silent! execute 'bdelete! %s'",
  --     bufnr
  --   )
  -- )
  return bufnr, win_id
end

local function get_next_float(wins)
  local cur_win = vim.api.nvim_get_current_win()
  local it = vim.iter(wins)
  it:find(cur_win)
  return it:next() or wins[1]
end

local function get_prev_float(wins)
  local cur_win = vim.api.nvim_get_current_win()
  local iter = vim.iter(wins)
  local prev_win = nil
  for win in iter do
    if win == cur_win then
      return prev_win or wins[#wins]
    end
    prev_win = win
  end
end

local function set_vertical_navigate_keymap(up_lhs, down_lhs, buffers, wins)
  for _, buffer in ipairs(buffers) do
    vim.keymap.set("n", up_lhs, function()
      vim.api.nvim_set_current_win(get_prev_float(wins))
    end, { buffer = buffer, noremap = true, silent = true })

    vim.keymap.set("n", down_lhs, function()
      vim.api.nvim_set_current_win(get_next_float(wins))
    end, { buffer = buffer, noremap = true, silent = true })
  end
end

local function register_auto_skip_when_insert(source_buf, target_win)
  vim.api.nvim_create_augroup("AutoSkipWhenInsert", { clear = true })
  vim.api.nvim_create_autocmd("InsertEnter", {
    group = "AutoSkipWhenInsert",
    buffer = source_buf,
    callback = function()
      if target_win then
        vim.api.nvim_set_current_win(target_win)
        vim.api.nvim_input "<Esc>"
      end
    end,
  })
end

function M.disable_auto_skip_when_insert()
  pcall(vim.api.nvim_del_augroup_by_name, "AutoSkipWhenInsert")
end

local function pop_win_stack(win)
  if floating_win_stack[win] then
    vim.api.nvim_set_current_win(
      vim.api.nvim_win_is_valid(floating_win_stack[win]) and floating_win_stack[win] or vim.api.nvim_list_wins()[1]
    )
    floating_win_stack[win] = nil
  end
end

local function delete_buf_in_win(win_id)
  local bufnr = vim.api.nvim_win_get_buf(win_id)
  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
end

local function register_close_for_wins(wins, group_prefix, close_post, close_prev)
  vim.api.nvim_create_augroup(group_prefix .. "AutoCloseWins", { clear = true })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group_prefix .. "AutoCloseWins",
    callback = function(args)
      local win = tonumber(args.match)
      if vim.tbl_contains(wins, win) then
        if close_prev then
          close_prev()
        end
        for _, other_win in ipairs(wins) do
          pop_win_stack(other_win)
          delete_buf_in_win(other_win)
          if other_win ~= win and vim.api.nvim_win_is_valid(other_win) then
            vim.api.nvim_win_close(other_win, true)
          end
        end
        pcall(vim.api.nvim_del_augroup_by_name, group_prefix .. "AutoCloseWins")
        if close_post then
          close_post()
        end
      end
    end,
  })
end

local function register_content_change(bufnr, win_id)
  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = util.debounce(100, function()
      local lines = vim.api.nvim_buf_line_count(bufnr)
      if lines == 0 then
        vim.api.nvim_set_option_value("cursorline", false, { win = win_id })
      elseif lines == 1 and vim.api.nvim_buf_get_lines(bufnr, 0, 1, true)[1] == "" then
        vim.api.nvim_set_option_value("cursorline", false, { win = win_id })
      else
        vim.api.nvim_set_option_value("cursorline", true, { win = win_id })
      end
    end),
  })
end

local function disable_input_enter_key(bufnr)
  vim.keymap.del("n", "<CR>", { buffer = bufnr, noremap = true, silent = true })
end

local function register_input_enter_handler(bufnr, enter_handler)
  vim.keymap.set("n", "<CR>", function()
    disable_input_enter_key(bufnr)
    enter_handler()
  end, { buffer = bufnr, noremap = true, silent = true })
end

function M.create_chat_win(server, enter_handler, close_prev, close_post)
  -- record where from
  local cur_win = vim.api.nvim_get_current_win()

  local chat_win = config.options.chat_win

  local width = math.floor(vim.o.columns * chat_win.width_percentage)

  local response_height = math.floor(vim.o.lines * chat_win.response_height_percentage)

  local input_height = math.floor(vim.o.lines * chat_win.input_height_percentage)

  local response_top = (vim.o.lines - response_height - input_height) / 2

  local input_top = (vim.o.lines - response_height - input_height) / 2 + response_height + 2

  local left = (vim.o.columns - width) / 2
  local response_buf, response_win =
    M.create_floating_window(width, response_height, response_top, left, chat_win.winblend, server)

  local input_buf, input_win =
    M.create_floating_window(width, input_height, input_top, left, chat_win.winblend, "input")

  -- set filetype
  vim.api.nvim_set_option_value("filetype", vim.g.inobit_filetype, { buf = input_buf })
  vim.api.nvim_set_option_value("filetype", vim.g.inobit_filetype, { buf = response_buf })

  -- push win stack
  floating_win_stack[input_win] = cur_win
  floating_win_stack[response_win] = cur_win

  vim.api.nvim_set_current_win(input_win)

  set_vertical_navigate_keymap(
    config.options.win_cursor_move_mappings.up,
    config.options.win_cursor_move_mappings.down,
    -- The order is the layout order.
    { response_buf, input_buf },
    { response_win, input_win }
  )

  register_content_change(response_buf, response_win)
  register_auto_skip_when_insert(response_buf, input_win)
  register_close_for_wins({ input_win, response_win }, server, close_post, close_prev)
  register_input_enter_handler(input_buf, enter_handler)

  return response_buf,
    response_win,
    input_buf,
    input_win,
    function()
      register_input_enter_handler(input_buf, enter_handler)
    end
end

local function register_picker_line_move(input_buf, content_buf, content_win)
  vim.keymap.set("n", "j", function()
    local lines = vim.api.nvim_buf_line_count(content_buf)
    local cur_line = vim.api.nvim_win_get_cursor(content_win)
    local next_line = nil
    if cur_line[1] + 1 > lines then
      next_line = 1
    else
      next_line = cur_line[1] + 1
    end
    vim.api.nvim_win_set_cursor(content_win, { next_line, 0 })
  end, { buffer = input_buf })

  vim.keymap.set("n", "k", function()
    local lines = vim.api.nvim_buf_line_count(content_buf)
    local cur_line = vim.api.nvim_win_get_cursor(content_win)
    local next_line = nil
    if cur_line[1] - 1 == 0 then
      next_line = lines
    else
      next_line = cur_line[1] - 1
    end
    vim.api.nvim_win_set_cursor(content_win, { next_line, 0 })
  end, { buffer = input_buf })
end

local function register_picker_data_filter(bufnr, filter_handler)
  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = util.debounce(100, function(_, _, _, first)
      filter_handler(vim.api.nvim_buf_get_lines(bufnr, first, -1, false)[1])
    end),
  })
end

local function register_picker_enter(input_buf, enter_handler)
  vim.keymap.set("n", "<CR>", function()
    enter_handler()
  end, { buffer = input_buf })
end

function M.create_select_picker(
  width_percentage,
  input_height,
  content_height_percentage,
  winblend,
  title,
  data_filter_wraper,
  enter_handler,
  close_post
)
  -- record where from
  local cur_win = vim.api.nvim_get_current_win()

  local width = math.floor(vim.o.columns * width_percentage)

  local content_height = math.floor(vim.o.lines * content_height_percentage)

  local input_top = (vim.o.lines - input_height - content_height) / 2

  local content_top = (vim.o.lines - input_height - content_height) / 2 + input_height + 2

  local left = (vim.o.columns - width) / 2

  local input_buf, input_win = M.create_floating_window(width, input_height, input_top, left, winblend, "filter")

  local content_buf, content_win = M.create_floating_window(width, content_height, content_top, left, winblend, title)

  -- set filetype
  vim.api.nvim_set_option_value("filetype", vim.g.inobit_filetype, { buf = input_buf })
  vim.api.nvim_set_option_value("filetype", vim.g.inobit_filetype, { buf = content_buf })

  -- push win stack
  floating_win_stack[input_win] = cur_win
  floating_win_stack[content_win] = cur_win

  vim.api.nvim_set_option_value("wrap", false, { win = content_win })
  vim.api.nvim_set_current_win(input_win)

  -- load data
  local data_filter = data_filter_wraper()

  register_close_for_wins({ input_win, content_win }, title, close_post)
  register_picker_line_move(input_buf, content_buf, content_win)
  register_content_change(content_buf, content_win)

  local filter_handler = function(input)
    vim.api.nvim_buf_set_lines(content_buf, 0, -1, false, data_filter(input))
  end
  register_picker_data_filter(input_buf, filter_handler)
  -- manual trigger
  filter_handler ""

  register_picker_enter(input_buf, function()
    local lines = vim.api.nvim_buf_get_lines(
      content_buf,
      vim.api.nvim_win_get_cursor(content_win)[1] - 1,
      vim.api.nvim_win_get_cursor(content_win)[1],
      false
    )
    if lines and lines[1] and lines[1] ~= "" then
      enter_handler(lines[1], input_win, content_win)
    end
  end)

  return input_buf, input_win, content_buf, content_win
end

return M
