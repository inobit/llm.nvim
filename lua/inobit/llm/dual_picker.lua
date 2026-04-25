-- lua/inobit/llm/dual_picker.lua
local M = {}

local config = require "inobit.llm.config"
local win = require "inobit.llm.win"
local models = require "inobit.llm.models"
local util = require "inobit.llm.util"
local notify = require "inobit.llm.notify"
local spinner = require "inobit.llm.spinner"

---@alias llm.dual_picker.Focus "provider" | "model"

---@class llm.dual_picker.Options
---@field title string
---@field provider_type ProviderType
---@field on_confirm fun(provider_name: string, model_id: string)
---@field close_prev_handler? fun()
---@field close_post_handler? fun()

---@class llm.DualPickerWin
---@field id string
---@field focus llm.dual_picker.Focus
---@field provider_type ProviderType  -- "chat" or "translate"
---@field input_win llm.win.FloatingWin
---@field provider_win llm.win.FloatingWin
---@field model_win llm.win.FloatingWin
---@field selected_provider string
---@field selected_model string?
---@field provider_list string[]
---@field filtered_provider_list string[]
---@field model_list string[]
---@field filtered_model_list string[]
---@field spinner_obj llm.FloatSpinner
---@field on_confirm fun(provider_name: string, model_id: string)
M.DualPickerWin = {}
M.DualPickerWin.__index = M.DualPickerWin

---@param opts llm.dual_picker.Options
---@return llm.DualPickerWin
function M.DualPickerWin:new(opts)
  self = { id = util.uuid() }
  setmetatable(self, M.DualPickerWin)

  self.on_confirm = opts.on_confirm
  self.provider_type = opts.provider_type
  self.focus = "model" -- Default focus on model (search and navigation target)
  self.spinner_obj = nil -- Will be created after model_win
  self.model_list = {}
  self.filtered_model_list = {}

  -- Get provider list from config
  -- chat type: only show chat-type providers
  -- translate type: show all providers (chat providers can be used for translation)
  self.provider_list = vim.tbl_filter(function(name)
    local p = config.providers[name]
    if opts.provider_type == "chat" then
      return p and p.provider_type == "chat"
    else
      -- translate type: show all providers
      return p ~= nil
    end
  end, vim.tbl_keys(config.providers))
  table.sort(self.provider_list)
  self.filtered_provider_list = self.provider_list

  if #self.provider_list == 0 then
    notify.error("No providers configured for type: " .. opts.provider_type)
    return self
  end

  self.selected_provider = self.provider_list[1]

  -- Create window layout
  self:_create_windows()

  -- Create spinner anchored to model_win
  self.spinner_obj = spinner.FloatSpinner:new(self.model_win)

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

  -- Set initial focus to input window
  vim.api.nvim_set_current_win(self.input_win.winid)
  vim.cmd.startinsert()

  return self
end

---@private
function M.DualPickerWin:_create_windows()
  local picker_opts = config.options.provider_picker_win

  -- Calculate dimensions (accounting for borders)
  -- Border adds 2 to width/height
  local total_width = math.floor(vim.o.columns * 0.7)
  -- Provider 20%, Model 80%, with 2-char gap between them
  local provider_width = math.floor(total_width * 0.2) - 1
  local model_width = total_width - provider_width - 2

  local input_height = picker_opts.input_height or 1
  local content_height = math.floor(vim.o.lines * picker_opts.content_height_percentage)

  -- Layout: Provider spans full height, Input+Model stacked on right
  -- Total height = input + content + borders (4)
  local total_height = input_height + content_height + 4
  local top_row = (vim.o.lines - total_height) / 2

  local col = (vim.o.columns - total_width) / 2
  local model_col = col + provider_width + 2 -- right side column

  -- Provider window (full height on left)
  ---@type llm.win.WinConfig
  local provider_opts = {
    width = provider_width,
    height = input_height + content_height + 2, -- +2 for gap between input and model
    row = top_row,
    col = col,
    winblend = picker_opts.winblend,
    zindex = win.WinStack._zindex,
    title = "Provider",
    relative = "editor",
    style = "minimal",
    border = "rounded",
    title_pos = "center",
  }

  -- Input window (top right, aligned with model)
  ---@type llm.win.WinConfig
  local input_opts = {
    width = model_width,
    height = input_height,
    row = top_row,
    col = model_col,
    winblend = picker_opts.winblend,
    zindex = win.WinStack._zindex,
    title = "Search",
    relative = "editor",
    style = "minimal",
    border = "rounded",
    title_pos = "center",
  }

  -- Model window (bottom right)
  ---@type llm.win.WinConfig
  local model_opts = {
    width = model_width,
    height = content_height,
    row = top_row + input_height + 2, -- +2 for input border
    col = model_col,
    winblend = picker_opts.winblend,
    zindex = win.WinStack._zindex,
    title = "Model",
    relative = "editor",
    style = "minimal",
    border = "rounded",
    title_pos = "center",
  }

  win.WinStack:_zindex_increment()

  self.provider_win = win.FloatingWin:new(provider_opts)
  self.input_win = win.FloatingWin:new(input_opts)
  self.model_win = win.FloatingWin:new(model_opts)

  -- Push to win stack
  local cur_win = vim.api.nvim_get_current_win()
  win.WinStack:push(self.provider_win.winid, cur_win)
  win.WinStack:push(self.input_win.winid, cur_win)
  win.WinStack:push(self.model_win.winid, cur_win)

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
  -- Search always filters model list, regardless of current focus
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

  -- Set default model based on provider_type
  local default_model
  if self.provider_type == "chat" then
    default_model = provider_config.default_chat_model or provider_config.default_model
  elseif self.provider_type == "translate" then
    default_model = provider_config.default_translate_model or provider_config.default_model
  else
    default_model = provider_config.default_model
  end

  if default_model and vim.tbl_contains(self.model_list, default_model) then
    self.selected_model = default_model
  elseif #self.model_list > 0 then
    self.selected_model = self.model_list[1]
  end

  -- Apply current filter and render
  local input = vim.api.nvim_buf_get_lines(self.input_win.bufnr, 0, 1, false)[1] or ""
  self.filtered_model_list = util.data_filter(input, self.model_list)
  self:_render_model_list()

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
  -- Insert mode: only Esc to exit, search applies to model only
  vim.keymap.set("i", "<Esc>", function()
    vim.cmd.stopinsert()
  end, { buffer = self.input_win.bufnr })

  vim.keymap.set("i", "<CR>", function()
    vim.cmd.stopinsert()
    self:_handle_enter()
  end, { buffer = self.input_win.bufnr })

  vim.keymap.set("i", "<Tab>", function()
    self:_switch_focus()
  end, { buffer = self.input_win.bufnr })

  -- Normal mode in input window: navigation and actions
  vim.keymap.set("n", "j", function()
    self:_move_cursor_down()
  end, { buffer = self.input_win.bufnr })

  vim.keymap.set("n", "k", function()
    self:_move_cursor_up()
  end, { buffer = self.input_win.bufnr })

  vim.keymap.set("n", "<Tab>", function()
    self:_switch_focus()
  end, { buffer = self.input_win.bufnr })

  vim.keymap.set("n", "<CR>", function()
    self:_handle_enter()
  end, { buffer = self.input_win.bufnr })

  vim.keymap.set("n", "r", function()
    self:refresh_models()
  end, { buffer = self.input_win.bufnr })

  -- Enter insert mode with i
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
    -- Move cursor to first model (keep search filter)
    if #self.filtered_model_list > 0 then
      vim.api.nvim_win_set_cursor(self.model_win.winid, { 1, 0 })
    end
  else
    self.focus = "provider"
    -- Move cursor to current selected provider
    local idx = 1
    for i, name in ipairs(self.provider_list) do
      if name == self.selected_provider then
        idx = i
        break
      end
    end
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

  -- Clean up windows before callback
  win.WinStack:delete(self.input_win.winid)
  win.WinStack:delete(self.provider_win.winid)
  win.WinStack:delete(self.model_win.winid)
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
          win.WinStack:pop(other.winid)
          pcall(vim.api.nvim_win_close, other.winid, true)
        end
        pcall(vim.api.nvim_del_augroup_by_name, self.id .. "close")
        if close_post_handler and w.bufnr == args.buf then
          close_post_handler()
        end
      end,
    })
  end
end

return M
