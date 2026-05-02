local M = {}

local stack = require "inobit.llm.ui.stack"
local base = require "inobit.llm.ui.base"
local config = require "inobit.llm.config"
local util = require "inobit.llm.util"

-- Export from dependencies
M.WinStack = stack.WinStack
M.FloatingWin = base.FloatingWin
M.SplitWin = base.SplitWin

---@alias llm.ui.ChatWinPane
---| "input"
---| "response"
---| "status"

---@class llm.ui.ChatWinOptions
---@field title? string
---@field input_bufnr? integer use existing bufnr
---@field response_bufnr? integer
---@field close_prev_handler? fun()
---@field close_post_handler? fun()

-- ============================================================================
-- Base Chat Window
-- ============================================================================

---@class llm.ui.BaseChatWin
---@field title string
---@field id string
---@field wins table<llm.ui.ChatWinPane, llm.ui.BaseWin>
M.BaseChatWin = {}
M.BaseChatWin.__index = M.BaseChatWin

---@protected
---@param close_prev_handler? fun()
---@param close_post_handler? fun()
function M.BaseChatWin:_register_close_chat_win(close_prev_handler, close_post_handler)
  local this = self
  for _, win in pairs(self.wins) do
    vim.keymap.set({ "n" }, "q", function()
      this:close(false, close_prev_handler, close_post_handler)
    end, { buffer = win.bufnr, noremap = true, silent = true })
  end
  -- Register WinClosed to handle :q or other close methods
  vim.api.nvim_create_augroup(self.id .. "close", { clear = false })
  for _, win in pairs(self.wins) do
    vim.api.nvim_create_autocmd("WinClosed", {
      group = self.id .. "close",
      buffer = win.bufnr,
      once = true,
      callback = function()
        this:close(false, close_prev_handler, close_post_handler)
      end,
    })
  end
end

---@protected
function M.BaseChatWin:_register_auto_skip_when_insert()
  vim.api.nvim_create_augroup(self.id .. "AutoSkipWhenInsert", { clear = true })
  vim.api.nvim_create_autocmd("InsertEnter", {
    group = self.id .. "AutoSkipWhenInsert",
    buffer = self.wins.response.bufnr,
    callback = function()
      if self.wins.input.winid then
        vim.api.nvim_set_current_win(self.wins.input.winid)
        vim.api.nvim_input "<Esc>"
      end
    end,
  })
end

---@protected
---Tab navigation only between input and response, not status
function M.BaseChatWin:_register_vertical_navigate_keymap()
  local nav_wins = { self.wins.input, self.wins.response }
  local function next_win()
    local cur_win = vim.api.nvim_get_current_win()
    local it = vim.iter(nav_wins)
    it:find(function(win)
      return win.winid == cur_win
    end)
    return it:next() or nav_wins[1]
  end
  for _, win in ipairs(nav_wins) do
    vim.keymap.set("n", "<Tab>", function()
      vim.api.nvim_set_current_win(next_win().winid)
    end, { buffer = win.bufnr, noremap = true, silent = true })
  end
end

---@class llm.ui.ResizeDimensions
---@field response {width: integer, height: integer, row?: number, col?: integer}
---@field status {width: integer, height: integer, row?: number, col?: integer}
---@field input {width: integer, height: integer, row?: number, col?: integer}

---@protected
---Calculate dimensions for resize. Override in subclasses.
---@return llm.ui.ResizeDimensions|nil
function M.BaseChatWin:_calculate_resize_dimensions()
  return nil
end

---@protected
---Register resize handler for VimResized event
function M.BaseChatWin:_register_resize_handler()
  local group = vim.api.nvim_create_augroup("llm_chatwin_resize_" .. self.id, { clear = true })

  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      local dims = self:_calculate_resize_dimensions()
      if not dims then
        return
      end

      -- Apply new dimensions to each window
      -- For float windows: use nvim_win_set_config with full config
      -- For split windows: use nvim_win_set_width/height
      -- IMPORTANT: Set heights from bottom to top (input -> status -> response)
      -- to avoid windows "borrowing" space from each other

      if dims.input and vim.api.nvim_win_is_valid(self.wins.input.winid) then
        if dims.input.row then
          -- Float window
          vim.api.nvim_win_set_config(self.wins.input.winid, {
            relative = "editor",
            width = dims.input.width,
            height = dims.input.height,
            row = dims.input.row,
            col = dims.input.col,
          })
        else
          -- Split window: just set height
          vim.api.nvim_win_set_height(self.wins.input.winid, dims.input.height)
        end
      end

      if dims.status and vim.api.nvim_win_is_valid(self.wins.status.winid) then
        if dims.status.row then
          -- Float window
          vim.api.nvim_win_set_config(self.wins.status.winid, {
            relative = "editor",
            width = dims.status.width,
            height = dims.status.height,
            row = dims.status.row,
            col = dims.status.col,
          })
        else
          -- Split window: just set height
          vim.api.nvim_win_set_height(self.wins.status.winid, dims.status.height)
        end
      end

      if dims.response and vim.api.nvim_win_is_valid(self.wins.response.winid) then
        if dims.response.row then
          -- Float window: use set_config
          vim.api.nvim_win_set_config(self.wins.response.winid, {
            relative = "editor",
            width = dims.response.width,
            height = dims.response.height,
            row = dims.response.row,
            col = dims.response.col,
          })
        else
          -- Split window: use set_width/height
          vim.api.nvim_win_set_width(self.wins.response.winid, dims.response.width)
          vim.api.nvim_win_set_height(self.wins.response.winid, dims.response.height)
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = {
      tostring(self.wins.response.winid),
      tostring(self.wins.input.winid),
    },
    callback = function()
      vim.api.nvim_del_augroup_by_id(group)
    end,
    once = true,
  })
end

---Close all windows
---@param delete_buffer? boolean
---@param close_prev_handler? fun()
---@param close_post_handler? fun()
function M.BaseChatWin:close(delete_buffer, close_prev_handler, close_post_handler)
  -- Prevent double close (e.g., q key triggers WinClosed)
  if self._closed then
    return
  end
  self._closed = true

  if close_prev_handler then
    close_prev_handler()
  end

  for _, win in pairs(self.wins) do
    M.WinStack:pop(win.winid)
    if delete_buffer then
      pcall(vim.api.nvim_buf_delete, win.bufnr, { force = true })
    end
    win:close()
  end

  if close_post_handler then
    close_post_handler()
  end
end

---Set status line content with highlights
---@param content string
function M.BaseChatWin:set_status_content(content)
  local status = self.wins.status
  if not status or not vim.api.nvim_buf_is_valid(status.bufnr) then
    return
  end

  vim.api.nvim_buf_set_lines(status.bufnr, 0, -1, false, { content })

  -- Ensure status window height remains 1 (for SplitWin)
  if vim.api.nvim_win_is_valid(status.winid) then
    vim.api.nvim_win_set_height(status.winid, 1)
  end

  -- Clear existing highlights
  vim.api.nvim_buf_clear_namespace(status.bufnr, -1, 0, -1)
  local ns = vim.api.nvim_create_namespace "llm_status_win"

  -- Match Multi:ON/Multi:OFF patterns
  local multi_on_start, multi_on_end = content:find "Multi:ON"
  if multi_on_start then
    vim.api.nvim_buf_set_extmark(status.bufnr, ns, 0, multi_on_start - 1, {
      end_row = 0,
      end_col = multi_on_end,
      hl_group = "DiagnosticOk",
    })
  end
  local multi_off_start, multi_off_end = content:find "Multi:OFF"
  if multi_off_start then
    vim.api.nvim_buf_set_extmark(status.bufnr, ns, 0, multi_off_start - 1, {
      end_row = 0,
      end_col = multi_off_end,
      hl_group = "DiagnosticWarn",
    })
  end

  -- Match Reason:ON/Reason:OFF patterns
  local reason_on_start, reason_on_end = content:find "Reason:ON"
  if reason_on_start then
    vim.api.nvim_buf_set_extmark(status.bufnr, ns, 0, reason_on_start - 1, {
      end_row = 0,
      end_col = reason_on_end,
      hl_group = "DiagnosticOk",
    })
  end
  local reason_off_start, reason_off_end = content:find "Reason:OFF"
  if reason_off_start then
    vim.api.nvim_buf_set_extmark(status.bufnr, ns, 0, reason_off_start - 1, {
      end_row = 0,
      end_col = reason_off_end,
      hl_group = "DiagnosticWarn",
    })
  end
end

---Get truncated display title (max display width 15)
---@param title? string
---@return string
function M.BaseChatWin:_get_display_title(title)
  local max_width = 15
  local display_title = title or ""
  local width = vim.fn.strdisplaywidth(display_title)
  if width > max_width then
    -- Need to truncate, find the position to cut
    local chars = vim.fn.split(display_title, "\\zs")
    local current_width = 0
    local result = ""
    for _, char in ipairs(chars) do
      local char_width = vim.fn.strdisplaywidth(char)
      if current_width + char_width > max_width - 3 then
        break
      end
      result = result .. char
      current_width = current_width + char_width
    end
    display_title = result .. "..."
  end
  return display_title
end

---Update the window title
---@param title string
function M.BaseChatWin:update_title(title)
  local display_title = self:_get_display_title(title)

  -- Update response window title for floating windows
  if self.wins.response and vim.api.nvim_win_is_valid(self.wins.response.winid) then
    local win_config = vim.api.nvim_win_get_config(self.wins.response.winid)
    local is_float = win_config.relative ~= ""
    if is_float then
      vim.api.nvim_win_set_config(self.wins.response.winid, {
        relative = "editor",
        title = display_title,
        title_pos = "center",
      })
    else
      -- For split windows, use winbar
      vim.api.nvim_set_option_value("winbar", " " .. display_title, { win = self.wins.response.winid })
    end
  end
end

-- ============================================================================
-- Float Chat Window
-- ============================================================================

---@class llm.ui.FloatChatWin: llm.ui.BaseChatWin
---@field title string
---@field id string
---@field wins table<llm.ui.ChatWinPane, llm.ui.FloatingWin>
M.FloatChatWin = setmetatable({}, { __index = M.BaseChatWin })
M.FloatChatWin.__index = M.FloatChatWin

---@param opts llm.ui.ChatWinOptions
---@return llm.ui.FloatChatWin
function M.FloatChatWin:new(opts)
  ---@type llm.ui.FloatChatWin
  local this = setmetatable({}, M.FloatChatWin)
  this.title = opts.title
  this.id = util.uuid()

  -- record where from
  local cur_win = vim.api.nvim_get_current_win()

  -- Use _calculate_resize_dimensions for initial layout calculation
  local dims = this:_calculate_resize_dimensions()

  -- Truncate title for display (max 15 chars)
  local display_title = this:_get_display_title(opts.title)

  -- Create windows
  local response_win = M.FloatingWin:new {
    width = dims.response.width,
    height = dims.response.height,
    row = dims.response.row,
    col = dims.response.col,
    winblend = config.options.float_chat.winblend,
    bufnr = opts.response_bufnr,
    zindex = M.WinStack._zindex,
    relative = "editor",
    style = "minimal",
    border = "rounded",
    focusable = true,
    title = display_title,
    title_pos = "center",
  }

  M.WinStack:_zindex_increment()

  local status_win = M.FloatingWin:new {
    width = dims.status.width,
    height = dims.status.height,
    row = dims.status.row,
    col = dims.status.col,
    winblend = config.options.float_chat.winblend,
    zindex = M.WinStack._zindex,
    relative = "editor",
    style = "minimal",
    border = "none",
    focusable = false,
  }

  M.WinStack:_zindex_increment()

  local input_win = M.FloatingWin:new {
    width = dims.input.width,
    height = dims.input.height,
    row = dims.input.row,
    col = dims.input.col,
    winblend = config.options.float_chat.winblend,
    title = "input",
    bufnr = opts.input_bufnr,
    zindex = M.WinStack._zindex,
    relative = "editor",
    style = "minimal",
    border = "rounded",
    title_pos = "center",
    focusable = true,
  }

  M.WinStack:_zindex_increment()

  this.wins = { response = response_win, status = status_win, input = input_win }

  -- Setup window options
  vim.api.nvim_set_option_value("filetype", config.FILETYPE, { buf = input_win.bufnr })
  vim.api.nvim_set_option_value("filetype", config.FILETYPE, { buf = response_win.bufnr })
  vim.api.nvim_set_option_value("filetype", config.FILETYPE, { buf = status_win.bufnr })

  vim.api.nvim_set_option_value("wrap", true, { win = response_win.winid })

  -- Set conceal options to hide block markers (window-local options)
  for _, win in ipairs { input_win.winid, response_win.winid, status_win.winid } do
    vim.api.nvim_set_option_value("conceallevel", 2, { win = win })
    vim.api.nvim_set_option_value("concealcursor", "nc", { win = win })
  end

  -- Push win stack
  M.WinStack:push(input_win.winid)
  M.WinStack:push(response_win.winid)

  vim.api.nvim_set_current_win(input_win.winid)

  response_win:register_content_change()

  -- Register events
  this:_register_vertical_navigate_keymap()
  this:_register_auto_skip_when_insert()
  this:_register_close_chat_win(opts.close_prev_handler, opts.close_post_handler)
  this:_register_resize_handler()

  return this
end

---@private
---Calculate dimensions for resize in float mode
---@return llm.ui.ResizeDimensions
function M.FloatChatWin:_calculate_resize_dimensions()
  local float_chat = config.options.float_chat
  local width = math.floor(vim.o.columns * float_chat.width_percentage)
  local status_height = 1
  local total_content_height = math.floor(vim.o.lines * 0.8) - status_height - 4
  local response_height = math.floor(total_content_height * 0.8)
  local input_height = total_content_height - response_height

  local total_height = response_height + status_height + input_height + 4
  local response_top = (vim.o.lines - total_height) / 2
  local status_top = response_top + response_height + 2
  local input_top = status_top + status_height + 0.5
  local left = (vim.o.columns - width) / 2

  return {
    response = {
      width = width,
      height = response_height,
      row = response_top,
      col = left,
    },
    status = {
      width = width,
      height = status_height,
      row = status_top,
      col = left,
    },
    input = {
      width = width,
      height = input_height,
      row = input_top,
      col = left,
    },
  }
end

-- ============================================================================
-- Split Chat Window
-- ============================================================================

---@class llm.ui.SplitChatWin: llm.ui.BaseChatWin
---@field title string
---@field id string
---@field wins table<llm.ui.ChatWinPane, llm.ui.SplitWin>
M.SplitChatWin = setmetatable({}, { __index = M.BaseChatWin })
M.SplitChatWin.__index = M.SplitChatWin

---@param opts llm.ui.ChatWinOptions
---@return llm.ui.SplitChatWin
function M.SplitChatWin:new(opts)
  ---@type llm.ui.SplitChatWin
  local this = setmetatable({}, M.SplitChatWin)
  this.title = opts.title
  this.id = util.uuid()

  -- record where from
  local cur_win = vim.api.nvim_get_current_win()

  -- Use _calculate_resize_dimensions for consistent calculation
  local dims = this:_calculate_resize_dimensions()
  local width = dims.response.width
  local response_height = dims.response.height
  local input_height = dims.input.height

  -- Create response window
  local response_winid, response_bufnr
  if opts.response_bufnr then
    vim.cmd("rightbelow vert sb " .. opts.response_bufnr)
    response_winid = vim.api.nvim_get_current_win()
    response_bufnr = opts.response_bufnr
  else
    vim.cmd "rightbelow vnew"
    response_winid = vim.api.nvim_get_current_win()
    response_bufnr = vim.api.nvim_win_get_buf(response_winid)
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = response_bufnr })
    vim.api.nvim_set_option_value("swapfile", false, { buf = response_bufnr })
    vim.api.nvim_set_option_value("buflisted", false, { buf = response_bufnr })
    vim.api.nvim_buf_set_name(response_bufnr, "inobit://llm/response_" .. response_bufnr)
  end
  vim.api.nvim_win_set_width(response_winid, width)

  -- Create status window (below response window, height=1)
  vim.cmd "belowright 1new"
  local status_winid = vim.api.nvim_get_current_win()
  local status_bufnr = vim.api.nvim_win_get_buf(status_winid)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = status_bufnr })
  vim.api.nvim_set_option_value("swapfile", false, { buf = status_bufnr })
  vim.api.nvim_set_option_value("buflisted", false, { buf = status_bufnr })
  vim.api.nvim_buf_set_name(status_bufnr, "inobit://llm/status_" .. status_bufnr)
  vim.api.nvim_set_option_value("cursorline", false, { win = status_winid })

  -- Create input window (below status window)
  local input_winid, input_bufnr
  if opts.input_bufnr then
    vim.cmd("belowright sb " .. opts.input_bufnr)
    input_winid = vim.api.nvim_get_current_win()
    input_bufnr = opts.input_bufnr
  else
    vim.cmd "belowright new"
    input_winid = vim.api.nvim_get_current_win()
    input_bufnr = vim.api.nvim_win_get_buf(input_winid)
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = input_bufnr })
    vim.api.nvim_set_option_value("swapfile", false, { buf = input_bufnr })
    vim.api.nvim_set_option_value("buflisted", false, { buf = input_bufnr })
    vim.api.nvim_buf_set_name(input_bufnr, "inobit://llm/input_" .. input_bufnr)
  end

  -- Now set heights in reverse order (input first, then response)
  -- Use resize command for more reliable height setting
  vim.api.nvim_set_current_win(input_winid)
  vim.cmd("resize " .. input_height)

  vim.api.nvim_set_current_win(status_winid)
  vim.cmd "resize 1"

  vim.api.nvim_set_current_win(response_winid)
  vim.cmd("resize " .. response_height)

  -- Set filetypes
  vim.api.nvim_set_option_value("filetype", config.FILETYPE, { buf = input_bufnr })
  vim.api.nvim_set_option_value("filetype", config.FILETYPE, { buf = response_bufnr })
  vim.api.nvim_set_option_value("filetype", config.FILETYPE, { buf = status_bufnr })

  -- Set wrap on response window
  vim.api.nvim_set_option_value("wrap", true, { win = response_winid })

  -- Set conceal options to hide block markers (window-local options)
  for _, winid in ipairs { input_winid, response_winid, status_winid } do
    vim.api.nvim_set_option_value("conceallevel", 2, { win = winid })
    vim.api.nvim_set_option_value("concealcursor", "nc", { win = winid })
  end

  -- Set winbar title for split window (truncated to 15 chars)
  local display_title = this:_get_display_title(opts.title)
  if display_title ~= "" then
    vim.api.nvim_set_option_value("winbar", " " .. display_title, { win = response_winid })
  end

  -- Push win stack
  M.WinStack:push(input_winid)
  M.WinStack:push(response_winid)

  -- Create window objects
  local response_win = M.SplitWin:new { bufnr = response_bufnr, winid = response_winid }
  local status_win = M.SplitWin:new { bufnr = status_bufnr, winid = status_winid }
  local input_win = M.SplitWin:new { bufnr = input_bufnr, winid = input_winid }

  this.wins = { response = response_win, status = status_win, input = input_win }

  -- Register content change for cursorline handling
  response_win:register_content_change()

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
---Calculate dimensions for resize in split mode
---Uses editor height for calculations since split windows may be resized
---@return llm.ui.ResizeDimensions
function M.SplitChatWin:_calculate_resize_dimensions()
  local split_chat = config.options.split_chat
  local width = math.floor(vim.o.columns * split_chat.width_percentage)

  -- Calculate based on editor height (available space for all windows)
  local editor_height = vim.o.lines - vim.o.cmdheight - 1

  -- Use a percentage of editor height to leave room for other windows
  local target_height = math.floor(editor_height * 0.85)

  -- Subtract status line height (1) for the content area
  local content_height = target_height - 1
  -- Ensure minimum content height
  if content_height < 8 then
    content_height = 8
  end

  local response_height = math.floor(content_height * 0.8)
  local input_height = content_height - response_height

  -- Ensure minimum heights
  if response_height < 5 then
    response_height = 5
  end
  if input_height < 2 then
    input_height = 2
  end

  return {
    response = {
      width = width,
      height = response_height,
    },
    status = {
      height = 1,
    },
    input = {
      height = input_height,
    },
  }
end

return M
