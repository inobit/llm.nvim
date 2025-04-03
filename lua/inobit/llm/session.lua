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
---@field name string
---@field create_time integer
---@field update_time integer
---@field server string
---@field model string
local SessionIndex = {}
SessionIndex.__index = SessionIndex

---@class llm.Session: llm.SessionIndex
---@field content llm.session.Message[]
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
    if k ~= "content" then
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

---@param new_name string
function SessionIndex:rename(new_name)
  self.name = new_name
  SessionManager:_save()
  notify.info("session renamed", string.format("session %s renamed to %s.", self.id, new_name))
end

function SessionIndex:delete()
  local path = self:get_file_path()
  if io.file_is_exist(path) then
    io.rm_file(path)
  end
  SessionManager.session_list[self.id] = nil
  SessionManager:_save()
  notify.info("session deleted", string.format("session %s deleted.", self.name))
end

---@param server string
---@param model string
---@return llm.Session
function Session:new(server, model)
  local id = util.uuid()
  local this = {
    id = id,
    name = id,
    create_time = os.time(),
    update_time = os.time(),
    server = server,
    model = model,
    content = {},
  }
  return setmetatable(this, Session)
end

---@param message llm.session.Message
function Session:add_message(message)
  table.insert(self.content, message)
  self.update_time = os.time()
end

--@private
function Session:_generate_session_name()
  if self.content[1].content then
    local name = ""
    for i = 0, vim.fn.strchars(self.content[1].content) - 1 do
      local char = vim.fn.strcharpart(self.content[1].content, i, 1)
      name = name .. char
      if i == 20 then
        break
      end
    end
    if name ~= "" then
      self.name = name
    end
  end
end

--- save current session and session index
function Session:save()
  io.write_json(self:get_file_path(), { id = self.id, content = self.content })
  if self.name == self.id then
    self:_generate_session_name()
  end
  SessionManager:_save()
  notify.info("session saved", string.format("session %s saved.", self.name))
end

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

---delete empty session(usually create by CTRL-N)
---@private
function SessionManager:_delete_empty_session()
  for id, session in pairs(self.session_list) do
    if
      getmetatable(session) == Session and #session--[[@as llm.Session]].content == 0
    then
      self.session_list[id] = nil
    end
  end
end

---@private
function SessionManager:_save()
  self:_delete_empty_session()
  local list = vim.tbl_map(function(item)
    if getmetatable(item) == SessionIndex then
      return item
    elseif getmetatable(item) == Session then
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

---@return string[]
function SessionManager:session_selector()
  if not self.session_list then
    return {}
  end
  local list = vim.tbl_values(self.session_list)
  -- sort by update_time
  table.sort(list, function(a, b)
    return a.update_time > b.update_time
  end)
  return vim
    .iter(list)
    :map(function(index)
      return string.format(
        "%s@%s %s %s",
        index.server,
        index.model,
        os.date("%Y-%m-%d %H:%M:%S", index.create_time),
        index.name
      )
    end)
    :totable()
end

---@param selected string
---@return llm.SessionIndex
function SessionManager:get_selected_session_index(selected)
  local server_model, create_time, name = selected:match "^(.-)%s(.-%s.-)%s(.*)"
  local session_index = vim.iter(vim.tbl_values(self.session_list)):find(function(index)
    return index.server .. "@" .. index.model == server_model
      and os.date("%Y-%m-%d %H:%M:%S", index.create_time) == create_time
      and index.name == name
  end)
  return session_index
end

---@param selected string
---@return llm.Session?
function SessionManager:get_selected_session(selected)
  local session_index = self:get_selected_session_index(selected)
  return self:get_session(session_index.id)
end

---@param callback? fun(session: llm.Session)
function SessionManager:open_selector(callback)
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
        if callback then
          callback(session)
        end
      end
    end,
  }
  self:_register_operator_keymap(picker.floats.input, picker.floats.content, picker.refresh_data)
end

-- <d> delete
-- <r> rename
---@private
---@param input_win llm.win.FloatingWin
---@param content_win llm.win.FloatingWin
---@param refresh fun()
function SessionManager:_register_operator_keymap(input_win, content_win, refresh)
  vim.keymap.set("n", "d", function()
    local line = util.get_current_line(content_win.bufnr, content_win.winid)
    if line then
      local session_index = self:get_selected_session_index(line)
      vim.ui.input({ prompt = "delete the session?(Y/N): " }, function(input)
        if input and input:lower() == "y" then
          session_index:delete()
          refresh()
        end
      end)
    end
  end, { buffer = input_win.bufnr, noremap = true, silent = true })
  vim.keymap.set("n", "r", function()
    local line = util.get_current_line(content_win.bufnr, content_win.winid)
    if line then
      local session_index = self:get_selected_session_index(line)
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
