local util = require "inobit.llm.util"
local config = require "inobit.llm.config"
local io = require "inobit.llm.io"
local Path = require "plenary.path"
local win = require "inobit.llm.win"
local notify = require "inobit.llm.notify"

---@class llm.session.Message
---@field role string
---@field reasoning_content? string
---@field content? string

---@class llm.SessionIndex
---@field id string
---@field title string
---@field title_generated_at? integer
---@field forked_from? string
---@field inherited_count integer
---@field create_time integer
---@field update_time integer
---@field server string
---@field model string
local SessionIndex = {}
SessionIndex.__index = SessionIndex

---@class llm.Session: llm.SessionIndex
---@field content llm.session.Message[]
---@field _title_generation_job? vim.SystemObj
local Session = {}
Session.__index = Session
-- extend SessionIndex
setmetatable(Session, SessionIndex)

---@class llm.SessionManager
---@field session_list table<string, llm.SessionIndex>
---@field session_list_path string
local SessionManager = {}
SessionManager.__index = SessionManager

---@return string
function SessionIndex:get_file_path()
  return Path:new(config.get_session_dir(), self.id .. ".json").filename
end

---@param session llm.Session
---@return llm.SessionIndex
function SessionIndex.toIndex(session)
  local new_session = vim.iter(session):fold({}, function(acc, k, v)
    -- Skip content and private fields (starting with _)
    if k ~= "content" and not k:match "^_" then
      acc[k] = v
    end
    return acc
  end)
  return setmetatable(new_session, SessionIndex)
end

---@param index llm.SessionIndex
function SessionIndex:new(index)
  return setmetatable(index, SessionIndex)
end

---@param new_title string
function SessionIndex:rename(new_title)
  self.title = new_title
  SessionManager:_save()
  notify.info("session renamed.", string.format("session %s renamed to %s.", self.id, new_title))
end

---@param on_post_delete? fun(success: boolean)
function SessionIndex:delete(on_post_delete)
  -- Execute session deletion
  local path = self:get_file_path()
  local success = false
  if io.file_is_exist(path) then
    io.rm_file(path)
    success = true
  end
  SessionManager.session_list[self.id] = nil
  SessionManager:_save()

  -- Post-delete callback
  if on_post_delete then
    on_post_delete(success)
  end
end

---@param server string
---@param model string
---@return llm.Session
function Session:new(server, model)
  local id = util.uuid()
  local this = {
    id = id,
    title = id,
    create_time = os.time(),
    update_time = os.time(),
    server = server,
    model = model,
    inherited_count = 0,
    content = {},
  }
  return setmetatable(this, Session)
end

---@param message llm.session.Message
function Session:add_message(message)
  table.insert(self.content, message)
  self.update_time = os.time()
end

--- save current session and session index
---@param opts? { silent?: boolean }
function Session:save(opts)
  opts = opts or {}

  -- when session is deleted,it can't be saved when it hasn't been recycled yet
  if not SessionManager.session_list[self.id] then
    return
  end

  if #self.content == 0 then
    if not opts.silent then
      notify.warn("empty session does not need to be saved.", string.format("session %s is empty.", self.id))
    end
    return
  end

  io.write_json(self:get_file_path(), { id = self.id, content = self.content })

  SessionManager:_save()

  if not opts.silent then
    notify.info("session saved.", string.format("session %s saved.", self.title))
  end
end

---filter the thinking messages
---@return llm.session.Message[]
function Session:multi_round_filter()
  return vim.tbl_filter(function(message)
    return not message.reasoning_content
  end, self.content)
end

---@param id string
function SessionManager:get_file_path(id)
  return Path:new(config.get_session_dir(), id .. ".json").filename
end

---@private
function SessionManager:_save()
  local list = vim.tbl_map(function(item)
    if getmetatable(item) == SessionIndex then
      return item
    elseif
      -- only save session with content
      getmetatable(item) == Session and #item--[[@as llm.Session]].content > 0
    then
      return SessionIndex.toIndex(item)
    end
  end, self.session_list)
  io.write_json(self.session_list_path, list)
end

---@param server string
---@param model string
---@return llm.Session
function SessionManager:new_session(server, model)
  local session = Session:new(server, model)
  -- add to list
  self.session_list[session.id] = session
  return session
end

---@param source_session llm.Session
---@param carry_rounds integer|"all"|{start: integer, ["end"]: integer}
---@return llm.Session
function SessionManager:fork_session(source_session, carry_rounds)
  local new_session = Session:new(source_session.server, source_session.model)

  -- Calculate messages to copy
  local messages_to_copy = {}
  if carry_rounds == "all" then
    messages_to_copy = vim.deepcopy(source_session.content)
  elseif type(carry_rounds) == "table" then
    -- Custom range in rounds: {start = x, end = y} or {start = x} (end defaults to last round)
    local total_rounds = math.floor(#source_session.content / 2)
    local start_round = math.max(1, carry_rounds.start or 1)
    local end_round = math.min(carry_rounds["end"] or total_rounds, total_rounds)
    -- Convert round numbers to message indices
    local start_idx = 2 * start_round - 1
    local end_idx = end_round * 2
    for i = start_idx, end_idx do
      table.insert(messages_to_copy, vim.deepcopy(source_session.content[i]))
    end
  else
    -- Specific round number: carry_rounds = 5 means the 5th round
    local round_idx = carry_rounds
    local start_idx = 2 * round_idx - 1
    local end_idx = round_idx * 2
    if start_idx <= #source_session.content then
      for i = start_idx, math.min(end_idx, #source_session.content) do
        table.insert(messages_to_copy, vim.deepcopy(source_session.content[i]))
      end
    end
  end

  -- Copy messages
  for _, msg in ipairs(messages_to_copy) do
    new_session:add_message(msg)
  end

  -- Set fork markers
  new_session.forked_from = source_session.id
  new_session.inherited_count = #messages_to_copy

  -- Initial title
  new_session.title = "Fork: " .. source_session.title

  -- Add to session list
  self.session_list[new_session.id] = new_session

  -- Save the forked session immediately
  new_session:save { silent = true }

  return new_session
end

---@param id string
---@return llm.Session?
function SessionManager:load(id)
  local path = self:get_file_path(id)
  if not io.file_is_exist(path) then
    notify.warn("file is not exist", string.format("session file %s not exist.", id))
    return
  end
  local content = io.read_json(path)
  local session = vim.tbl_deep_extend("force", {}, self.session_list[id], content)
  -- ensure inherited_count has a default value
  if session.inherited_count == nil then
    session.inherited_count = 0
  end
  -- cache the session
  SessionManager.session_list[id] = session
  return setmetatable(session, Session)
end

---open selected session
---@param id string
---@return llm.Session?
function SessionManager:get_session(id)
  if self.session_list[id] and getmetatable(self.session_list[id]) == Session then
    return self.session_list[id] --[[@as llm.Session]]
  else
    return self:load(id)
  end
end

---@param str string
---@param max_len integer
---@return string
function SessionManager:_truncate(str, max_len)
  if vim.fn.strchars(str) > max_len then
    return vim.fn.strcharpart(str, 0, max_len - 3) .. "..."
  end
  return str
end

---@param content string
---@param max_chars integer
---@return string
function SessionManager:_extract_summary(content, max_chars)
  local c = 0
  local summary = ""
  for i = 0, vim.fn.strchars(content) - 1 do
    local char = vim.fn.strcharpart(content, i, 1)
    if not string.match(char, "^%s$") then
      summary = summary .. char
      c = c + 1
    end
    if c == max_chars then
      break
    end
  end
  return summary
end

---@param session llm.SessionIndex
---@return string
function SessionManager:_format_session_title(session)
  -- Directly return the title (whether generated or default id)
  return session.title or session.id
end

---@return string[]
function SessionManager:session_selector()
  if not self.session_list then
    return {}
  end
  local list = vim.tbl_values(self.session_list)
  table.sort(list, function(a, b)
    return a.update_time > b.update_time
  end)
  return vim
    .iter(list)
    :map(function(index)
      local prefix = index.forked_from and "└" or "  "
      local title = self:_format_session_title(index)
      return string.format(
        "%s[%s@%s] %s %s",
        prefix,
        index.server,
        index.model,
        os.date("%Y-%m-%d %H:%M", index.update_time),
        title
      )
    end)
    :totable()
end

---@param selected string
---@return llm.SessionIndex?
function SessionManager:get_selected_session_index(selected)
  -- 格式: "  [server@model] 2024-01-15 10:30 title" 或 "└[server@model] 2024-01-15 10:30 title"
  local _, server_model, update_time, title =
    selected:match "^([%s└]*)%[([^%]]+)%]%s+(%d%d%d%d%-%d%d%-%d%d %d%d:%d%d)%s+(.*)$"
  if not server_model or not update_time then
    return nil
  end
  local session_index = vim.iter(vim.tbl_values(self.session_list)):find(function(index)
    return index.server .. "@" .. index.model == server_model
      and os.date("%Y-%m-%d %H:%M", index.update_time) == update_time
      and index.title == title
  end)
  return session_index
end

---@param selected string
---@return llm.Session?
function SessionManager:get_selected_session(selected)
  local session_index = self:get_selected_session_index(selected)
  if session_index then
    return self:get_session(session_index.id)
  end
end

---@param select_callback? fun(session: llm.Session)
---@param delete_callback? fun(session: llm.SessionIndex, refresh: fun(), input_win: llm.win.FloatingWin)
function SessionManager:open_selector(select_callback, delete_callback)
  local picker = win.PickerWin:new {
    title = "sessions",
    data_filter_wraper = function()
      local data = self:session_selector()
      return function(input)
        return util.data_filter(input, data)
      end
    end,
    winOptions = config.options.session_picker_win,
    enter_handler = function(selected)
      local session = self:get_selected_session(selected)
      if session then
        if select_callback then
          select_callback(session)
        end
      end
    end,
  }
  self:_register_operator_keymap(picker.wins.input, picker.wins.content, picker.refresh_data, delete_callback)
end

-- <d> delete
-- <r> rename
---@private
---@param input_win llm.win.FloatingWin
---@param content_win llm.win.FloatingWin
---@param refresh fun()
---@param delete_callback? fun(session: llm.SessionIndex, refresh: fun(), input_win: llm.win.FloatingWin)
function SessionManager:_register_operator_keymap(input_win, content_win, refresh, delete_callback)
  vim.keymap.set("n", "d", function()
    local line = util.get_current_line(content_win.bufnr, content_win.winid)
    if not line then
      return
    end

    vim.ui.input({ prompt = "delete the session?(Y/N): " }, function(input)
      if not input or input:lower() ~= "y" then
        return
      end

      local session_index = self:get_selected_session_index(line)
      if not session_index then
        return
      end

      if delete_callback then
        delete_callback(session_index, refresh, input_win)
      else
        session_index:delete(function(_)
          refresh()
          -- Restore focus to picker input window
          if vim.api.nvim_win_is_valid(input_win.winid) then
            vim.api.nvim_set_current_win(input_win.winid)
          end
        end)
      end
    end)
  end, { buffer = input_win.bufnr, noremap = true, silent = true })

  vim.keymap.set("n", "r", function()
    local line = util.get_current_line(content_win.bufnr, content_win.winid)
    if line then
      local session_index = self:get_selected_session_index(line)
      if not session_index then
        return
      end
      vim.ui.input({ prompt = "rename to: " }, function(input)
        if input then
          session_index:rename(input)
          refresh()
        end
      end)
    end
  end, { buffer = input_win.bufnr, noremap = true, silent = true })
end

---init session manager before use
---@param force? boolean can force to refresh
---@return llm.SessionManager
function SessionManager:init(force)
  if force then
    local path = Path:new(config.get_session_dir(), "index.json").filename
    self.session_list_path = path
    if io.file_is_exist(path) then
      local session_list = io.read_json(path)
      session_list = session_list and session_list or {}
      -- just change value
      session_list = vim.tbl_map(function(item)
        return SessionIndex:new(item)
      end, session_list)
      self.session_list = session_list
    else
      self.session_list = {}
    end
  end
  return self
end

return SessionManager:init(true)
