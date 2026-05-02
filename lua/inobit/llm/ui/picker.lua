local M = {}

local stack = require "inobit.llm.ui.stack"
local base = require "inobit.llm.ui.base"
local config = require "inobit.llm.config"
local util = require "inobit.llm.util"
local notify = require "inobit.llm.notify"
local spinner = require "inobit.llm.spinner"
local models = require "inobit.llm.models"
-- ProviderManager is loaded lazily in DualPickerWin to avoid circular dependency

-- Export from dependencies
M.WinStack = stack.WinStack
M.FloatingWin = base.FloatingWin

-- ============================================================================
-- Picker Window (from win.lua)
-- ============================================================================

---@alias llm.ui.pickerWin.PaneKind
---| "input"
---| "content"

---@alias llm.ui.PickerWinSize "tiny" | "small" | "medium" | "large"

---@class llm.ui.PickerWinOptions
---@field title string
---@field size? llm.ui.PickerWinSize default "medium"
---@field items string[] initial data list
---@field on_change? fun(input: string): string[] filter callback, return new list
---@field on_select fun(selected: string) confirm callback
---@field on_close? fun() close callback
---@field close_prev_handler? fun()
---@field close_post_handler? fun()

---@class llm.ui.PickerWin
---@field title string
---@field id string
---@field wins table<llm.ui.pickerWin.PaneKind, llm.ui.FloatingWin>
---@field _items string[]
---@field _on_change? fun(input: string): string[]
---@field _on_select fun(selected: string)
---@field _on_close? fun()
---@field _close_prev_handler? fun()
---@field _close_post_handler? fun()
---@field _closed? boolean
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
    vim.api.nvim_set_option_value("cursorline", true, { win = self.wins.content.winid })
  end, { buffer = self.wins.input.bufnr })
end

function M.PickerWin:close()
  if self._closed then
    return
  end
  self._closed = true

  if self._close_prev_handler then
    self._close_prev_handler()
  end

  if self._on_close then
    self._on_close()
  end

  -- Close windows and delete buffers
  for _, win in pairs(self.wins) do
    pcall(vim.api.nvim_buf_delete, win.bufnr, { force = true })
    win:close()
  end

  if self._close_post_handler then
    self._close_post_handler()
  end

  -- Pop from stack and restore focus to top valid window
  for _, win in pairs(self.wins) do
    M.WinStack:pop(win.winid)
  end
end

---@private
function M.PickerWin:_register_close_picker_win()
  local this = self
  for _, win in pairs(self.wins) do
    vim.keymap.set({ "n" }, "q", function()
      this:close()
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
        this:close()
      end,
    })
  end
end

---@private
---@param enter_handler fun()
function M.PickerWin:_register_picker_enter(enter_handler)
  vim.keymap.set("n", "<CR>", function()
    enter_handler()
  end, { buffer = self.wins.input.bufnr })
end

---@param opts llm.ui.PickerWinOptions
---@return llm.ui.PickerWin
function M.PickerWin:new(opts)
  ---@type llm.ui.PickerWin
  local this = setmetatable({}, M.PickerWin)
  this.title = opts.title
  this.id = util.uuid()

  local cur_win = vim.api.nvim_get_current_win()

  -- Size configurations
  local size = opts.size or "medium"
  local size_config = {
    tiny = { width = 0.2, height = 0.2 },
    small = { width = 0.3, height = 0.3 },
    medium = { width = 0.5, height = 0.5 },
    large = { width = 0.8, height = 0.8 },
  }
  local selected_config = size_config[size] or size_config.medium

  local input_height = 1
  local width = math.floor(vim.o.columns * selected_config.width)
  local content_height = math.floor(vim.o.lines * selected_config.height)
  local input_top = (vim.o.lines - input_height - content_height) / 2
  local content_top = input_top + input_height + 2
  local left = (vim.o.columns - width) / 2

  local input_win = M.FloatingWin:new {
    width = width,
    height = input_height,
    row = input_top,
    col = left,
    winblend = 0,
    zindex = M.WinStack._zindex,
    title = "input",
    relative = "editor",
    style = "minimal",
    border = "rounded",
    title_pos = "center",
    focusable = true,
  }

  local content_win = M.FloatingWin:new {
    width = width,
    height = content_height,
    row = content_top,
    col = left,
    winblend = 0,
    zindex = M.WinStack._zindex,
    title = opts.title,
    relative = "editor",
    style = "minimal",
    border = "rounded",
    title_pos = "center",
    focusable = true,
  }

  M.WinStack:_zindex_increment()

  this.wins = { input = input_win, content = content_win }
  this._items = opts.items or {}
  this._on_change = opts.on_change
  this._on_select = opts.on_select
  this._on_close = opts.on_close
  this._close_prev_handler = opts.close_prev_handler
  this._close_post_handler = opts.close_post_handler

  M.WinStack:push(input_win.winid)
  M.WinStack:push(content_win.winid)

  vim.api.nvim_set_option_value("wrap", false, { win = content_win.winid })
  vim.api.nvim_set_current_win(input_win.winid)

  content_win:register_content_change()
  this:_register_close_picker_win()
  this:_register_picker_line_move()

  -- Initial render
  this:update_items(this._items)

  -- Register input filter
  this:_register_input_filter()

  -- Register enter handler
  this:_register_picker_enter(function()
    local line = util.get_current_line(content_win.bufnr, content_win.winid)
    if line and this._on_select then
      this._on_select(line)
      this:close()
    end
  end)

  return this
end

---Update displayed items
---@param items string[]
function M.PickerWin:update_items(items)
  self._items = items
  if self.wins.content and vim.api.nvim_buf_is_valid(self.wins.content.bufnr) then
    vim.api.nvim_buf_set_lines(self.wins.content.bufnr, 0, -1, false, items)
  end
end

---@private
function M.PickerWin:_register_input_filter()
  local this = self
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = this.wins.input.bufnr,
    callback = function()
      local input = vim.api.nvim_buf_get_lines(this.wins.input.bufnr, 0, 1, false)[1] or ""
      if this._on_change then
        local filtered = this._on_change(input)
        this:update_items(filtered)
      end
    end,
  })
end

-- ============================================================================
-- Dual Picker Window (from dual_picker.lua)
-- ============================================================================

---@alias llm.ui.DualPickerFocus "provider" | "model"

---@class llm.ui.DualPickerOptions
---@field title string
---@field scenario Scenario
---@field on_confirm fun(provider_name: string, model_id: string)
---@field close_prev_handler? fun()
---@field close_post_handler? fun()

---@class llm.ui.DualPickerWin
---@field id string
---@field focus llm.ui.DualPickerFocus
---@field scenario Scenario
---@field input_win llm.ui.FloatingWin
---@field provider_win llm.ui.FloatingWin
---@field model_win llm.ui.FloatingWin
---@field selected_provider string
---@field selected_model string?
---@field provider_list string[]
---@field filtered_provider_list string[]
---@field model_list string[]
---@field filtered_model_list string[]
---@field spinner_obj llm.WinSpinner
---@field on_confirm fun(provider_name: string, model_id: string)
M.DualPickerWin = {}
M.DualPickerWin.__index = M.DualPickerWin

---@param opts llm.ui.DualPickerOptions
---@return llm.ui.DualPickerWin
function M.DualPickerWin:new(opts)
  -- Lazy load ProviderManager to avoid circular dependency
  local ProviderManager = require "inobit.llm.provider"

  self = { id = util.uuid() }
  setmetatable(self, M.DualPickerWin)

  self.on_confirm = opts.on_confirm
  self.scenario = opts.scenario
  self.focus = "provider" -- Default focus on provider
  self.spinner_obj = nil -- Will be created after model_win
  self.model_list = {}
  self.filtered_model_list = {}

  -- Get provider list for the specified scenario
  self.provider_list = ProviderManager:get_providers_for_scenario(opts.scenario)
  self.filtered_provider_list = self.provider_list

  if #self.provider_list == 0 then
    notify.error("No providers configured for scenario: " .. opts.scenario)
    return self
  end

  self.selected_provider = self.provider_list[1]

  -- Create window layout
  self:_create_windows()

  -- Create spinner anchored to model_win
  self.spinner_obj = spinner.WinSpinner:new(self.model_win, "top-left")

  -- Populate provider list
  self:_render_provider_list()

  -- Load models for selected provider
  self:load_models(self.selected_provider)

  -- Register keymaps
  self:_register_keymaps()

  -- Register input filter
  self:_register_input_filter()

  -- Register close handler
  self:_register_close_handler(opts.close_prev_handler, opts.close_post_handler)

  -- Set initial focused border color
  self:_update_focus_border()

  -- Set focus to the focused window (provider initially)
  local target_win = self.focus == "provider" and self.provider_win.winid or self.model_win.winid
  vim.api.nvim_set_current_win(target_win)

  return self
end

---@private
function M.DualPickerWin:_create_windows()
  -- Calculate dimensions (accounting for borders)
  -- Border adds 2 to width/height
  local total_width = math.floor(vim.o.columns * 0.7)
  -- Provider 20%, Model 80%, with 2-char gap between them
  local provider_width = math.floor(total_width * 0.2) - 1
  local model_width = total_width - provider_width - 2

  local input_height = 1
  local content_height = math.floor(vim.o.lines * 0.5)

  -- Layout: Provider spans full height, Input+Model stacked on right
  -- Total height = input + content + borders (4)
  local total_height = input_height + content_height + 4
  local top_row = (vim.o.lines - total_height) / 2

  local col = (vim.o.columns - total_width) / 2
  local model_col = col + provider_width + 2 -- right side column

  -- Provider window (full height on left)
  ---@type llm.ui.WinConfig
  local provider_opts = {
    width = provider_width,
    height = input_height + content_height + 2, -- +2 for gap between input and model
    row = top_row,
    col = col,
    winblend = 0,
    zindex = M.WinStack._zindex,
    title = "Provider",
    relative = "editor",
    style = "minimal",
    border = "rounded",
    title_pos = "center",
  }

  -- Input window (top right, aligned with model)
  ---@type llm.ui.WinConfig
  local input_opts = {
    width = model_width,
    height = input_height,
    row = top_row,
    col = model_col,
    winblend = 0,
    zindex = M.WinStack._zindex,
    title = "Search",
    relative = "editor",
    style = "minimal",
    border = "rounded",
    title_pos = "center",
  }

  -- Model window (bottom right)
  ---@type llm.ui.WinConfig
  local model_opts = {
    width = model_width,
    height = content_height,
    row = top_row + input_height + 2, -- +2 for input border
    col = model_col,
    winblend = 0,
    zindex = M.WinStack._zindex,
    title = "Model",
    relative = "editor",
    style = "minimal",
    border = "rounded",
    title_pos = "center",
  }

  M.WinStack:_zindex_increment()

  self.provider_win = M.FloatingWin:new(provider_opts)
  self.input_win = M.FloatingWin:new(input_opts)
  self.model_win = M.FloatingWin:new(model_opts)

  -- Push to win stack
  local cur_win = vim.api.nvim_get_current_win()
  M.WinStack:push(self.provider_win.winid)
  M.WinStack:push(self.input_win.winid)
  M.WinStack:push(self.model_win.winid)

  -- Set options
  vim.api.nvim_set_option_value("wrap", false, { win = self.provider_win.winid })
  vim.api.nvim_set_option_value("wrap", false, { win = self.model_win.winid })
end

---@private
function M.DualPickerWin:_render_provider_list()
  local display_lines = {}
  for i, name in ipairs(self.filtered_provider_list) do
    display_lines[i] = string.format("%2d. %s", i, name)
  end
  vim.api.nvim_buf_set_lines(self.provider_win.bufnr, 0, -1, false, display_lines)
  if #self.filtered_provider_list > 0 then
    vim.api.nvim_win_set_cursor(self.provider_win.winid, { 1, 0 })
    vim.api.nvim_set_option_value("cursorline", true, { win = self.provider_win.winid })
  end
end

---@private
function M.DualPickerWin:_render_model_list()
  local display_lines = {}
  for i, name in ipairs(self.filtered_model_list) do
    display_lines[i] = string.format("%3d. %s", i, name)
  end
  vim.api.nvim_buf_set_lines(self.model_win.bufnr, 0, -1, false, display_lines)
  if #display_lines > 0 then
    vim.api.nvim_win_set_cursor(self.model_win.winid, { 1, 0 })
    vim.api.nvim_set_option_value("cursorline", true, { win = self.model_win.winid })
  end
end

---@private
function M.DualPickerWin:_apply_filter()
  -- Search only filters model list when focus is on model
  if self.focus ~= "model" then
    return
  end
  local input = vim.api.nvim_buf_get_lines(self.input_win.bufnr, 0, 1, false)[1] or ""
  self.filtered_model_list = util.data_filter(input, self.model_list)
  self:_render_model_list()
  -- Update selected model to first match
  if #self.filtered_model_list > 0 then
    self.selected_model = self.filtered_model_list[1]
  end
end

---@private
function M.DualPickerWin:_register_input_filter()
  vim.api.nvim_create_autocmd("TextChanged", {
    buffer = self.input_win.bufnr,
    callback = function()
      self:_apply_filter()
    end,
  })

  vim.api.nvim_create_autocmd("TextChangedI", {
    buffer = self.input_win.bufnr,
    callback = function()
      self:_apply_filter()
    end,
  })
end

---@private
function M.DualPickerWin:_start_spinner()
  if self.spinner_obj then
    self.spinner_obj:start()
  end
end

---@private
function M.DualPickerWin:_stop_spinner()
  if self.spinner_obj then
    self.spinner_obj:stop()
  end
end

---@param provider_name string
function M.DualPickerWin:load_models(provider_name)
  self.selected_provider = provider_name
  self.selected_model = nil

  local provider_config = config.providers[provider_name]
  if not provider_config then
    self.model_list = {}
    self.filtered_model_list = {}
    self:_render_model_list()
    return
  end

  -- Get model overrides first (these are always available immediately)
  local model_overrides = config.normalize_model_overrides(provider_config.model_overrides)
  local override_models = vim.tbl_keys(model_overrides)
  table.sort(override_models)

  -- Set initial list from overrides
  self.model_list = override_models
  self.filtered_model_list = override_models

  -- Apply current filter and render
  local input = vim.api.nvim_buf_get_lines(self.input_win.bufnr, 0, 1, false)[1] or ""
  self.filtered_model_list = util.data_filter(input, self.model_list)
  self:_render_model_list()

  -- Set initial selected model to first item
  if #self.filtered_model_list > 0 then
    self.selected_model = self.filtered_model_list[1]
  end

  -- Fetch additional models asynchronously if enabled
  if provider_config.fetch_models then
    self:_start_spinner()
    models.get_models(provider_name, provider_config, function(fetched_models)
      vim.schedule(function()
        -- Merge: overrides first, then fetched (excluding duplicates)
        local fetched_ids = vim.tbl_map(function(m)
          return m.id
        end, fetched_models)
        local seen = {}
        for _, id in ipairs(override_models) do
          seen[id] = true
        end
        local fetched_sorted = vim.tbl_filter(function(id)
          return not seen[id]
        end, fetched_ids)
        table.sort(fetched_sorted)

        -- Update model list
        self.model_list = vim.list_extend(override_models, fetched_sorted)

        -- Stop spinner and render final list
        self:_stop_spinner()

        -- Re-apply filter
        local current_input = vim.api.nvim_buf_get_lines(self.input_win.bufnr, 0, 1, false)[1] or ""
        self.filtered_model_list = util.data_filter(current_input, self.model_list)
        self:_render_model_list()

        -- Update selection if needed
        if not self.selected_model and #self.filtered_model_list > 0 then
          self.selected_model = self.filtered_model_list[1]
        end
      end)
    end)
  end
end

---@private
function M.DualPickerWin:_register_keymaps()
  -- Helper to register keymaps for all three windows
  local function register_for_all_windows(modes, keys, callback)
    for _, win in ipairs { self.input_win, self.provider_win, self.model_win } do
      for _, mode in ipairs(modes) do
        vim.keymap.set(mode, keys, callback, { buffer = win.bufnr, silent = true })
      end
    end
  end

  -- Insert mode: only Esc to exit, search applies to model only
  vim.keymap.set("i", "<Esc>", function()
    vim.cmd.stopinsert()
  end, { buffer = self.input_win.bufnr })

  vim.keymap.set("i", "<CR>", function()
    vim.cmd.stopinsert()
    self:_handle_enter()
  end, { buffer = self.input_win.bufnr })

  -- Tab to switch focus - available in all windows
  register_for_all_windows({ "i", "n" }, "<Tab>", function()
    self:_switch_focus()
  end)

  -- Normal mode navigation - available in all windows
  register_for_all_windows({ "n" }, "j", function()
    self:_move_cursor_down()
  end)

  register_for_all_windows({ "n" }, "k", function()
    self:_move_cursor_up()
  end)

  register_for_all_windows({ "n" }, "<CR>", function()
    self:_handle_enter()
  end)

  register_for_all_windows({ "n" }, "r", function()
    self:refresh_models()
  end)

  -- Enter insert mode with i - only in input window
  vim.keymap.set("n", "i", function()
    vim.cmd.startinsert()
  end, { buffer = self.input_win.bufnr })
end

---@private
function M.DualPickerWin:_move_cursor_down()
  local winid = self.focus == "provider" and self.provider_win.winid or self.model_win.winid
  local bufnr = self.focus == "provider" and self.provider_win.bufnr or self.model_win.bufnr
  local list = self.focus == "provider" and self.filtered_provider_list or self.filtered_model_list
  local lines = vim.api.nvim_buf_line_count(bufnr)
  local cur_line = vim.api.nvim_win_get_cursor(winid)[1]

  local next_line = cur_line + 1 > lines and 1 or cur_line + 1
  vim.api.nvim_win_set_cursor(winid, { next_line, 0 })
  vim.api.nvim_set_option_value("cursorline", true, { win = winid })

  -- Update selection
  if next_line <= #list then
    local item = list[next_line]
    if self.focus == "provider" then
      self.selected_provider = item
      self:load_models(item)
    else
      self.selected_model = item
    end
  end
end

---@private
function M.DualPickerWin:_move_cursor_up()
  local winid = self.focus == "provider" and self.provider_win.winid or self.model_win.winid
  local bufnr = self.focus == "provider" and self.provider_win.bufnr or self.model_win.bufnr
  local list = self.focus == "provider" and self.filtered_provider_list or self.filtered_model_list
  local lines = vim.api.nvim_buf_line_count(bufnr)
  local cur_line = vim.api.nvim_win_get_cursor(winid)[1]

  local next_line = cur_line - 1 == 0 and lines or cur_line - 1
  vim.api.nvim_win_set_cursor(winid, { next_line, 0 })
  vim.api.nvim_set_option_value("cursorline", true, { win = winid })

  -- Update selection
  if next_line <= #list then
    local item = list[next_line]
    if self.focus == "provider" then
      self.selected_provider = item
      self:load_models(item)
    else
      self.selected_model = item
    end
  end
end

---@private
function M.DualPickerWin:_switch_focus()
  -- Toggle focus between provider and model
  if self.focus == "provider" then
    self.focus = "model"
    -- Move cursor to input window and enter insert mode
    vim.api.nvim_set_current_win(self.input_win.winid)
    vim.cmd.startinsert()
  else
    self.focus = "provider"
    vim.cmd.stopinsert()
    -- Move cursor to current selected provider
    local idx = 1
    for i, name in ipairs(self.provider_list) do
      if name == self.selected_provider then
        idx = i
        break
      end
    end
    vim.api.nvim_set_current_win(self.provider_win.winid)
    vim.api.nvim_win_set_cursor(self.provider_win.winid, { idx, 0 })
  end
  -- Update focused border color
  self:_update_focus_border()
end

---@private
function M.DualPickerWin:_update_focus_border()
  -- Get CurSearch background color and use it for focused border foreground
  local cur_search_hl = vim.api.nvim_get_hl(0, { name = "CurSearch", link = false })
  local border_fg = cur_search_hl.bg

  -- Create a custom highlight group with CurSearch bg color for focused border
  vim.api.nvim_set_hl(0, "DualPickerFocusedBorder", { fg = border_fg })

  local focused_win = self.focus == "provider" and self.provider_win.winid or self.model_win.winid
  local unfocused_win = self.focus == "provider" and self.model_win.winid or self.provider_win.winid

  -- Reset unfocused window to default FloatBorder
  vim.api.nvim_set_option_value("winhl", "FloatBorder:FloatBorder", { win = unfocused_win })
  -- Set focused window to CurSearch color border
  vim.api.nvim_set_option_value("winhl", "FloatBorder:DualPickerFocusedBorder", { win = focused_win })
end

---@private
function M.DualPickerWin:_handle_enter()
  if self.focus == "provider" then
    -- Switch to model focus on Enter
    self:_switch_focus()
  else
    -- Confirm selection when focus is on model
    if self.selected_provider and self.selected_model then
      self:_confirm_selection()
    else
      notify.warn "No model selected"
    end
  end
end

---@private
function M.DualPickerWin:_confirm_selection()
  -- Stop spinner if running
  self:_stop_spinner()

  -- Clean up windows before callback (skip_focus, let WinClosed handle focus)
  self.input_win:close()
  self.provider_win:close()
  self.model_win:close()

  -- Call confirm callback
  self.on_confirm(self.selected_provider, self.selected_model)
end

function M.DualPickerWin:refresh_models()
  local provider_config = config.providers[self.selected_provider]
  if not provider_config or not provider_config.fetch_models then
    notify.info "Provider does not support dynamic model fetch"
    return
  end

  -- Force fetch (bypass cache)
  self:_start_spinner()

  models.fetch_models(provider_config, function(model_list, error)
    vim.schedule(function()
      self:_stop_spinner()
      if error then
        notify.error("Failed to fetch models: " .. error)
        return
      end

      if model_list then
        models.save_models_cache(self.selected_provider, model_list)
      end

      -- Reload with fresh cache
      self:load_models(self.selected_provider)
    end)
  end)
end

---@private
---@param close_prev_handler? fun()
---@param close_post_handler? fun()
function M.DualPickerWin:_register_close_handler(close_prev_handler, close_post_handler)
  local wins = { self.input_win, self.provider_win, self.model_win }

  vim.api.nvim_create_augroup(self.id .. "close", { clear = true })
  for _, w in ipairs(wins) do
    vim.keymap.set("n", "q", function()
      vim.api.nvim_win_close(w.winid, true)
    end, { buffer = w.bufnr, noremap = true, silent = true })

    vim.keymap.set("i", "<Esc>", function()
      vim.cmd.stopinsert()
      vim.api.nvim_win_close(w.winid, true)
    end, { buffer = self.input_win.bufnr, noremap = true, silent = true })

    vim.api.nvim_create_autocmd("WinClosed", {
      group = self.id .. "close",
      buffer = w.bufnr,
      callback = function(args)
        if close_prev_handler and w.bufnr == args.buf then
          close_prev_handler()
        end
        for _, other in ipairs(wins) do
          pcall(vim.api.nvim_win_close, other.winid, true)
        end
        pcall(vim.api.nvim_del_augroup_by_name, self.id .. "close")
        if close_post_handler and w.bufnr == args.buf then
          close_post_handler()
        end
        -- Pop all windows from stack and restore focus to top valid window
        for _, other in ipairs(wins) do
          M.WinStack:pop(other.winid)
        end
      end,
    })
  end
end

return M
