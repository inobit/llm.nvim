local M = {}
local config = require "inobit.llm.config"
local util = require "inobit.llm.util"
local notify = require "inobit.llm.notify"

---@class llm.win.WinStack
---@field _zindex integer
M.WinStack = {}

M.WinStack._zindex = 100

function M.WinStack:_zindex_increment()
  self._zindex = self._zindex + 1
end

---@type table<integer, integer>
M.WinStack.stack = {}

---@param winid integer
---@param from_winid integer
function M.WinStack:push(winid, from_winid)
  self.stack[winid] = from_winid
end

---@param winid integer
function M.WinStack:delete(winid)
  self.stack[winid] = nil
end

---@param winid integer
function M.WinStack:pop(winid)
  if self.stack[winid] and vim.api.nvim_win_is_valid(self.stack[winid]) then
    vim.api.nvim_set_current_win(self.stack[winid])
    self:delete(winid)
  end
end

---@class llm.win.WinConfig: vim.api.keyset.win_config
---@field winblend? integer
---@field bufnr? integer

-- Base window class
---@class llm.win.BaseWin
---@field bufnr integer
---@field winid integer
---@field close fun(self: llm.win.BaseWin)

-- Base chat window class
---@class llm.win.BaseChatWin
---@field title string
---@field id string
---@field wins table<string, llm.win.BaseWin>

---@class llm.win.FloatingWin: llm.win.BaseWin
---@field bufnr integer
---@field winid integer
M.FloatingWin = {}
M.FloatingWin.__index = M.FloatingWin

function M.FloatingWin:register_content_change()
  vim.api.nvim_buf_attach(self.bufnr, false, {
    on_lines = util.debounce(100, function()
      if vim.api.nvim_win_is_valid(self.winid) then
        local lines = vim.api.nvim_buf_line_count(self.bufnr)
        if lines == 0 then
          vim.api.nvim_set_option_value("cursorline", false, { win = self.winid })
        elseif lines == 1 and vim.api.nvim_buf_get_lines(self.bufnr, 0, 1, true)[1] == "" then
          vim.api.nvim_set_option_value("cursorline", false, { win = self.winid })
        else
          vim.api.nvim_set_option_value("cursorline", true, { win = self.winid })
        end
      end
    end),
  })
end

function M.FloatingWin:close()
  pcall(vim.api.nvim_win_close, self.winid, true)
end

---@param opts llm.win.WinConfig
---@return llm.win.FloatingWin
function M.FloatingWin:new(opts)
  ---@type llm.win.FloatingWin
  ---@diagnostic disable-next-line: missing-fields
  local this = {}
  local bufnr = opts.bufnr or vim.api.nvim_create_buf(false, true)
  local winblend = opts.winblend
  opts.winblend = nil
  opts.bufnr = nil
  local winid = vim.api.nvim_open_win(bufnr, false, opts)
  if winblend then
    vim.api.nvim_set_option_value("winblend", opts.winblend, { win = winid })
  end
  this.bufnr = bufnr
  this.winid = winid
  return setmetatable(this, M.FloatingWin)
end

---@class llm.win.PaddingFloatingWin: llm.win.FloatingWin
---@field private background? llm.win.FloatingWin
---@field body llm.win.FloatingWin
M.PaddingFloatingWin = {}
M.PaddingFloatingWin.__index = function(table, key)
  if key == "bufnr" then
    return table.body.bufnr
  elseif key == "winid" then
    return table.body.winid
  else
    return M.PaddingFloatingWin[key]
  end
end
setmetatable(M.PaddingFloatingWin, M.FloatingWin)

---@alias llm.win.Padding number | number[] top right bottom left

---@param opts llm.win.WinConfig
---@param padding? llm.win.Padding
---@return llm.win.PaddingFloatingWin
function M.PaddingFloatingWin:new(opts, padding)
  local this = {}
  setmetatable(this, M.PaddingFloatingWin)

  -- handle padding,just like css padding
  local total_padding = 0
  if padding then
    if type(padding) == "number" then
      padding = { padding, padding, padding, padding }
    elseif type(padding) == "table" and not vim.tbl_isempty(padding) then
      if #padding == 1 then
        padding = { padding[1], padding[1], padding[1], padding[1] }
      elseif #padding == 2 then -- top bottom, left right
        padding = { padding[1], padding[2], padding[1], padding[2] }
      elseif #padding == 3 then -- top,right left,bottom
        padding = { padding[1], padding[2], padding[3], padding[2] }
      else
        padding = { padding[1], padding[2], padding[3], padding[4] }
      end
    end
    for i, v in
      ipairs(padding --[=[@as number[] ]=])
    do
      if v < 0 then
        padding[i] = 0
        notify.warn "padding must be positive,has been processed to 0!"
      end
      total_padding = total_padding + padding[i]
    end
  end
  if total_padding == 0 then
    -- padding 0
    this.body = M.FloatingWin:new(opts)
    return this
  end

  -- setup background
  local background_opts = opts
  local body_opts = vim.tbl_deep_extend("force", {}, opts)
  background_opts.bufnr = nil
  background_opts.focusable = false
  local background = M.FloatingWin:new(background_opts)
  vim.api.nvim_set_option_value("cursorline", false, { win = background.winid })

  -- get relative size
  local background_width = vim.api.nvim_win_get_width(background.winid)
  local background_height = vim.api.nvim_win_get_height(background.winid)

  -- remove location-affecting options
  body_opts.anchor = nil
  body_opts.title = nil
  body_opts.title_pos = nil
  body_opts.footer = nil
  body_opts.footer_pos = nil
  body_opts.fixed = nil

  body_opts.relative = "win"
  body_opts.win = background.winid
  body_opts.style = "minimal"
  body_opts.border = "none"

  -- compute size
  local _padding = padding --[=[@as number[] ]=]
  body_opts.row = math.floor(_padding[1])
  body_opts.height = math.floor(background_height - _padding[1] - _padding[3])
  body_opts.col = math.floor(_padding[4])
  body_opts.width = math.floor(background_width - _padding[4] - _padding[2])

  this.body = M.FloatingWin:new(body_opts)
  this.background = background

  return this
end

function M.PaddingFloatingWin:close()
  if self.background then
    pcall(vim.api.nvim_win_close, self.background.winid, true)
    pcall(vim.api.nvim_buf_delete, self.background.bufnr, { force = true })
  end
  pcall(vim.api.nvim_win_close, self.body.winid, true)
end

---@param wins_id string
---@param wins llm.win.FloatingWin[]
---@param delete_buffer? boolean
---@param close_prev_handler? fun()
---@param close_post_handler? fun()
local function register_close_for_wins(wins_id, wins, delete_buffer, close_prev_handler, close_post_handler)
  vim.api.nvim_create_augroup(wins_id .. "close", { clear = false })
  for _, win in ipairs(wins) do
    vim.api.nvim_create_autocmd("WinClosed", {
      group = wins_id .. "close",
      buffer = win.bufnr,
      callback = function(args)
        if close_prev_handler and win.bufnr == args.buf then
          close_prev_handler()
        end
        for _, other_win in ipairs(wins) do
          M.WinStack:pop(other_win.winid)
          if delete_buffer then
            pcall(vim.api.nvim_buf_delete, other_win.bufnr, { force = true })
          end
          pcall(vim.api.nvim_win_close, other_win.winid, true)
        end
        pcall(vim.api.nvim_del_augroup_by_name, wins_id .. "close")
        pcall(vim.api.nvim_del_augroup_by_name, wins_id .. "AutoSkipWhenInsert")
        if close_post_handler and win.bufnr == args.buf then
          close_post_handler()
        end
      end,
    })
  end
end

---@param wins_id string
---@param source_bufnr integer
---@param target_winid integer
local function register_auto_skip_when_insert(wins_id, source_bufnr, target_winid)
  vim.api.nvim_create_augroup(wins_id .. "AutoSkipWhenInsert", { clear = true })
  vim.api.nvim_create_autocmd("InsertEnter", {
    group = wins_id .. "AutoSkipWhenInsert",
    buffer = source_bufnr,
    callback = function()
      if target_winid then
        vim.api.nvim_set_current_win(target_winid)
        vim.api.nvim_input "<Esc>"
      end
    end,
  })
end

---@param wins llm.win.FloatingWin[]
local function register_vertical_navigate_keymap(wins)
  ---@return llm.win.FloatingWin
  local function next_win()
    local cur_win = vim.api.nvim_get_current_win()
    local it = vim.iter(wins)
    it:find(function(win)
      return win.winid == cur_win
    end)
    return it:next() or wins[1]
  end
  for _, win in ipairs(wins) do
    -- switch window
    vim.keymap.set("n", "<Tab>", function()
      vim.api.nvim_set_current_win(next_win().winid)
    end, { buffer = win.bufnr, noremap = true, silent = true })
  end
end

---@alias llm.win.ChatWinPane
---| "input"
---| "response"

---@class llm.win.ChatWinOptions
---@field title string
---@field input_bufnr? integer use existing bufnr
---@field response_bufnr? integer
---@field close_prev_handler? fun()
---@field close_post_handler? fun()

---@class llm.win.ChatWin: llm.win.BaseChatWin
---@field title string
---@field id string
---@field wins table<llm.win.ChatWinPane, llm.win.FloatingWin>
M.ChatWin = {}
M.ChatWin.__index = M.ChatWin

---@private
---@param close_prev_handler? fun()
---@param close_post_handler? fun()
function M.ChatWin:_register_close_chat_win(close_prev_handler, close_post_handler)
  for _, win in pairs(self.wins) do
    vim.keymap.set({ "n" }, "q", function()
      vim.api.nvim_win_close(win.winid, true)
    end, { buffer = win.bufnr, noremap = true, silent = true })
  end
  register_close_for_wins(self.id, vim.tbl_values(self.wins), false, close_prev_handler, close_post_handler)
end

---@private
function M.ChatWin:_register_auto_skip_when_insert()
  register_auto_skip_when_insert(self.id, self.wins.response.bufnr, self.wins.input.winid)
end

---@private
function M.ChatWin:_register_vertical_navigate_keymap()
  register_vertical_navigate_keymap(vim.tbl_values(self.wins))
end

---@param opts llm.win.ChatWinOptions
---@return llm.win.ChatWin
function M.ChatWin:new(opts)
  ---@type llm.win.ChatWin
  ---@diagnostic disable-next-line: missing-fields
  local this = { title = opts.title, id = util.uuid() }
  setmetatable(this, M.ChatWin)

  -- record where from
  local cur_win = vim.api.nvim_get_current_win()

  local chat_win = config.options.chat_win

  local width = math.floor(vim.o.columns * chat_win.width_percentage)

  local response_height = math.floor(vim.o.lines * chat_win.content_height_percentage)

  local input_height = math.floor(vim.o.lines * chat_win.input_height_percentage)

  local response_top = (vim.o.lines - response_height - input_height) / 2

  local input_top = (vim.o.lines - response_height - input_height) / 2 + response_height + 2

  local left = (vim.o.columns - width) / 2

  ---@type llm.win.WinConfig
  local response_opts = {
    width = width,
    height = response_height,
    row = response_top,
    col = left,
    winblend = chat_win.winblend,
    title = opts.title,
    bufnr = opts.response_bufnr,
    zindex = M.WinStack._zindex,
    relative = "editor",
    style = "minimal",
    border = "rounded",
    title_pos = "center",
    focusable = true,
  }

  ---@type llm.win.WinConfig
  local input_opts = {
    width = width,
    height = input_height,
    row = input_top,
    col = left,
    winblend = chat_win.winblend,
    title = "input",
    bufnr = opts.input_bufnr,
    zindex = M.WinStack._zindex,
    relative = "editor",
    style = "minimal",
    border = "rounded",
    title_pos = "center",
    focusable = true,
  }

  local response_win = M.FloatingWin:new(response_opts)

  local input_win = M.FloatingWin:new(input_opts)

  M.WinStack:_zindex_increment()

  this.wins = { response = response_win, input = input_win }

  -- set filetype
  -- vim.api.nvim_set_option_value("readonly", true, { buf = response_win.bufnr })
  vim.api.nvim_set_option_value("filetype", vim.g.inobit_filetype, { buf = input_win.bufnr })
  vim.api.nvim_set_option_value("filetype", vim.g.inobit_filetype, { buf = response_win.bufnr })

  -- setup wrap
  vim.api.nvim_set_option_value("wrap", true, { win = response_win.winid })

  -- push win stack
  M.WinStack:push(input_win.winid, cur_win)
  M.WinStack:push(response_win.winid, cur_win)

  vim.api.nvim_set_current_win(input_win.winid)

  response_win:register_content_change()

  -- register events
  this:_register_vertical_navigate_keymap()
  this:_register_auto_skip_when_insert()
  this:_register_close_chat_win(opts.close_prev_handler, opts.close_post_handler)

  return this
end

---@alias llm.win.pickerWin.PaneKind
---| "input"
---| "content"

---@class llm.win.PickerWinOptions
---@field title string
---@field winOptions llm.WinOptions
---@field data_filter_wraper? fun(): fun(input: string): string[]
---@field enter_handler? fun(selected: string)
---@field close_prev_handler? fun()
---@field close_post_handler? fun()

---@class llm.win.PickerWin
---@field title string
---@field id string
---@field wins table<llm.win.pickerWin.PaneKind, llm.win.FloatingWin>
---@field refresh_data fun()
M.PickerWin = {}
M.PickerWin.__index = M.PickerWin

function M.PickerWin:_register_picker_line_move()
  vim.keymap.set("n", "j", function()
    local lines = vim.api.nvim_buf_line_count(self.wins.content.bufnr)
    local cur_line = vim.api.nvim_win_get_cursor(self.wins.content.winid)
    local next_line = nil
    if cur_line[1] + 1 > lines then
      next_line = 1
    else
      next_line = cur_line[1] + 1
    end
    vim.api.nvim_win_set_cursor(self.wins.content.winid, { next_line, 0 })
    -- BUG: the cursor sometimes does't move in wezterm mux mode, must refresh every time
    vim.api.nvim_set_option_value("cursorline", true, { win = self.wins.content.winid })
  end, { buffer = self.wins.input.bufnr })

  vim.keymap.set("n", "k", function()
    local lines = vim.api.nvim_buf_line_count(self.wins.content.bufnr)
    local cur_line = vim.api.nvim_win_get_cursor(self.wins.content.winid)
    local next_line = nil
    if cur_line[1] - 1 == 0 then
      next_line = lines
    else
      next_line = cur_line[1] - 1
    end
    vim.api.nvim_win_set_cursor(self.wins.content.winid, { next_line, 0 })
    -- BUG: the cursor sometimes does't move in wezterm mux mode, must refresh every time
    vim.api.nvim_set_option_value("cursorline", true, { win = self.wins.content.winid })
  end, { buffer = self.wins.input.bufnr })
end

---@private
---@param close_prev_handler fun()
---@param close_post_handler fun()
function M.PickerWin:_register_close_picker_win(close_prev_handler, close_post_handler)
  for _, win in pairs(self.wins) do
    vim.keymap.set({ "n" }, "q", function()
      vim.api.nvim_win_close(win.winid, true)
    end, { buffer = win.bufnr, noremap = true, silent = true })
  end
  register_close_for_wins(self.id, vim.tbl_values(self.wins), true, close_prev_handler, close_post_handler)
end

---@private
---@param filter_handler fun(string)
function M.PickerWin:_register_picker_data_filter(filter_handler)
  vim.api.nvim_buf_attach(self.wins.input.bufnr, false, {
    on_lines = util.debounce(100, function(_, _, _, first)
      filter_handler(vim.api.nvim_buf_get_lines(self.wins.input.bufnr, first, -1, false)[1])
    end),
  })
end

---@private
---@param enter_handler fun()
function M.PickerWin:_register_picker_enter(enter_handler)
  vim.keymap.set("n", "<CR>", function()
    enter_handler()
  end, { buffer = self.wins.input.bufnr })
end

---@param opts llm.win.PickerWinOptions
---@return llm.win.PickerWin
function M.PickerWin:new(opts)
  ---@type llm.win.PickerWin
  ---@diagnostic disable-next-line: missing-fields
  local this = { title = opts.title, id = util.uuid() }
  this = setmetatable(this, M.PickerWin)
  -- record where from
  local cur_win = vim.api.nvim_get_current_win()

  opts.winOptions.input_height = opts.winOptions.input_height or 1

  local width = math.floor(vim.o.columns * opts.winOptions.width_percentage)

  local content_height = math.floor(vim.o.lines * opts.winOptions.content_height_percentage)

  local input_top = (vim.o.lines - opts.winOptions.input_height - content_height) / 2

  local content_top = (vim.o.lines - opts.winOptions.input_height - content_height) / 2
    + opts.winOptions.input_height
    + 2

  local left = (vim.o.columns - width) / 2

  ---@type llm.win.WinConfig
  local input_opts = {
    width = width,
    height = opts.winOptions.input_height,
    row = input_top,
    col = left,
    winblend = opts.winOptions.winblend,
    zindex = M.WinStack._zindex,
    title = "input",
    relative = "editor",
    style = "minimal",
    border = "rounded",
    title_pos = "center",
    focusable = true,
  }

  ---@type llm.win.WinConfig
  local content_opts = {
    width = width,
    height = content_height,
    row = content_top,
    col = left,
    winblend = opts.winOptions.winblend,
    zindex = M.WinStack._zindex,
    title = opts.title,
    relative = "editor",
    style = "minimal",
    border = "rounded",
    title_pos = "center",
    focusable = true,
  }

  local input_win = M.FloatingWin:new(input_opts)

  local content_win = M.FloatingWin:new(content_opts)

  M.WinStack:_zindex_increment()

  this.wins = { input = input_win, content = content_win }

  -- set filetype
  -- vim.api.nvim_set_option_value("filetype", vim.g.inobit_filetype, { buf = input_win.bufnr })
  -- vim.api.nvim_set_option_value("filetype", vim.g.inobit_filetype, { buf = content_win.bufnr })

  -- push win stack
  M.WinStack:push(input_win.winid, cur_win)
  M.WinStack:push(content_win.winid, cur_win)

  vim.api.nvim_set_option_value("wrap", false, { win = content_win.winid })
  vim.api.nvim_set_current_win(input_win.winid)

  content_win:register_content_change()
  this:_register_close_picker_win(opts.close_prev_handler, opts.close_post_handler)
  this:_register_picker_line_move()

  --HACK: isn't normal way to do this
  local _fn = {}
  local filter_handler = setmetatable({}, _fn)
  -- for external data refresh
  function this.refresh_data()
    local data_filter = opts.data_filter_wraper()
    _fn.__call = function(_, input)
      vim.api.nvim_buf_set_lines(content_win.bufnr, 0, -1, false, data_filter(input))
    end
    -- manual trigger
    filter_handler(vim.api.nvim_buf_get_lines(input_win.bufnr, 0, -1, false)[1])
  end
  this.refresh_data()
  ---@diagnostic disable-next-line: param-type-mismatch
  this:_register_picker_data_filter(filter_handler)

  this:_register_picker_enter(function()
    local line = util.get_current_line(content_win.bufnr, content_win.winid)
    if line then
      if opts.enter_handler then
        opts.enter_handler(line)
      end
      -- the return is not via stack at this time, it should be deleted in advance to avoid being triggered by the winclosed event.
      M.WinStack:delete(input_win.winid)
      M.WinStack:delete(content_win.winid)
      input_win:close()
      content_win:close()
    end
  end)

  return this
end

---@class llm.win.SplitWin: llm.win.BaseWin
---@field bufnr integer
---@field winid integer
M.SplitWin = {}
M.SplitWin.__index = M.SplitWin

function M.SplitWin:close()
  pcall(vim.api.nvim_win_close, self.winid, true)
end

---@param opts {bufnr?: integer, winid?: integer}
---@return llm.win.SplitWin
function M.SplitWin:new(opts)
  local this = {}
  this.bufnr = opts.bufnr
  this.winid = opts.winid
  return setmetatable(this, M.SplitWin)
end

---@class llm.win.SplitChatWin: llm.win.BaseChatWin
---@field title string
---@field id string
---@field wins table<llm.win.ChatWinPane, llm.win.SplitWin>
M.SplitChatWin = {}
M.SplitChatWin.__index = M.SplitChatWin

---@private
---@param close_prev_handler? fun()
---@param close_post_handler? fun()
function M.SplitChatWin:_register_close_chat_win(close_prev_handler, close_post_handler)
  for _, win in pairs(self.wins) do
    vim.keymap.set({ "n" }, "q", function()
      vim.api.nvim_win_close(win.winid, true)
    end, { buffer = win.bufnr, noremap = true, silent = true })
  end
  register_close_for_wins(self.id, vim.tbl_values(self.wins), false, close_prev_handler, close_post_handler)
end

---@private
function M.SplitChatWin:_register_auto_skip_when_insert()
  register_auto_skip_when_insert(self.id, self.wins.response.bufnr, self.wins.input.winid)
end

---@private
function M.SplitChatWin:_register_vertical_navigate_keymap()
  register_vertical_navigate_keymap(vim.tbl_values(self.wins))
end

---@param opts llm.win.ChatWinOptions
---@return llm.win.SplitChatWin
function M.SplitChatWin:new(opts)
  ---@type llm.win.SplitChatWin
  ---@diagnostic disable-next-line: missing-fields
  local this = { title = opts.title, id = util.uuid() }
  setmetatable(this, M.SplitChatWin)

  -- record where from
  local cur_win = vim.api.nvim_get_current_win()

  local vsplit_win = config.options.vsplit_win
  local width = math.floor(vim.o.columns * vsplit_win.width_percentage)

  -- Calculate heights
  local total_height = vim.o.lines - vim.o.cmdheight - 2 -- minus status line and command line
  local response_height = math.floor(total_height * 0.8)
  local input_height = total_height - response_height - 2 -- -2 for separator

  -- Create response window
  local response_winid, response_bufnr
  if opts.response_bufnr then
    -- Reuse existing buffer: create window with that buffer on the right
    vim.cmd("rightbelow vert sb " .. opts.response_bufnr)
    response_winid = vim.api.nvim_get_current_win()
    response_bufnr = opts.response_bufnr
  else
    -- Create new window with new buffer
    vim.cmd "rightbelow vnew"
    response_winid = vim.api.nvim_get_current_win()
    response_bufnr = vim.api.nvim_win_get_buf(response_winid)
    -- Set as scratch buffer (similar to FloatWin)
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = response_bufnr })
    vim.api.nvim_set_option_value("swapfile", false, { buf = response_bufnr })
    vim.api.nvim_set_option_value("buflisted", false, { buf = response_bufnr })
    vim.api.nvim_buf_set_name(response_bufnr, "inobit://llm/response_" .. response_bufnr)
  end
  vim.api.nvim_win_set_width(response_winid, width)

  -- Create input window
  local input_winid, input_bufnr
  if opts.input_bufnr then
    -- Reuse existing buffer: create window with that buffer
    vim.cmd("sb " .. opts.input_bufnr)
    input_winid = vim.api.nvim_get_current_win()
    input_bufnr = opts.input_bufnr
  else
    -- Create new window with new buffer
    vim.cmd "new"
    input_winid = vim.api.nvim_get_current_win()
    input_bufnr = vim.api.nvim_win_get_buf(input_winid)
    -- Set as scratch buffer
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = input_bufnr })
    vim.api.nvim_set_option_value("swapfile", false, { buf = input_bufnr })
    vim.api.nvim_set_option_value("buflisted", false, { buf = input_bufnr })
    vim.api.nvim_buf_set_name(input_bufnr, "inobit://llm/input_" .. input_bufnr)
  end
  vim.api.nvim_win_set_height(input_winid, input_height)

  -- Set filetypes
  local filetype = vim.g.inobit_filetype or "inobit"
  vim.api.nvim_set_option_value("filetype", filetype, { buf = input_bufnr })
  vim.api.nvim_set_option_value("filetype", filetype, { buf = response_bufnr })

  -- Set wrap on response window
  vim.api.nvim_set_option_value("wrap", true, { win = response_winid })

  -- Push win stack
  M.WinStack:push(input_winid, cur_win)
  M.WinStack:push(response_winid, cur_win)

  -- Set title (use winbar or buffer name)
  vim.api.nvim_set_option_value("winbar", opts.title, { win = response_winid })
  vim.api.nvim_set_option_value("winbar", "input", { win = input_winid })

  -- Create SplitWin objects
  local response_win = M.SplitWin:new { bufnr = response_bufnr, winid = response_winid }
  local input_win = M.SplitWin:new { bufnr = input_bufnr, winid = input_winid }

  this.wins = { response = response_win, input = input_win }

  -- Focus input window
  vim.api.nvim_set_current_win(input_winid)

  -- Register events
  this:_register_vertical_navigate_keymap()
  this:_register_auto_skip_when_insert()
  this:_register_close_chat_win(opts.close_prev_handler, opts.close_post_handler)
  this:_register_resize_handler()

  return this
end

---@private
function M.SplitChatWin:_register_resize_handler()
  local group = vim.api.nvim_create_augroup("llm_splitchatwin_resize_" .. self.id, { clear = true })
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      -- Recalculate and set window sizes
      local vsplit_win = config.options.vsplit_win
      local new_width = math.floor(vim.o.columns * vsplit_win.width_percentage)
      local total_height = vim.o.lines - vim.o.cmdheight - 2
      local new_response_height = math.floor(total_height * 0.8)
      local new_input_height = total_height - new_response_height - 2

      if vim.api.nvim_win_is_valid(self.wins.response.winid) then
        vim.api.nvim_win_set_width(self.wins.response.winid, new_width)
        vim.api.nvim_win_set_height(self.wins.response.winid, new_response_height)
      end
      if vim.api.nvim_win_is_valid(self.wins.input.winid) then
        vim.api.nvim_win_set_height(self.wins.input.winid, new_input_height)
      end
    end,
  })

  -- Clean up autocmd when windows are closed
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = { tostring(self.wins.response.winid), tostring(self.wins.input.winid) },
    callback = function()
      vim.api.nvim_del_augroup_by_id(group)
    end,
    once = true,
  })
end

return M
