local log = require "inobit.llm.log"
local Path = require "plenary.path"
local Job = require "plenary.job"
local uv = vim.uv or vim.loop
local default_mod = 438 --0666

local M = {}

function M.handle_exit_code(code)
  local msg
  if not code then
    msg = "Something went wrong."
  end
  if code == 0 then
    msg = "Request succeeded!"
  elseif code == 1 then
    msg = "Unsupported protocol or malformed URL."
  elseif code == 6 then
    msg = "Could not resolve host."
  elseif code == 7 then
    msg = "Failed to connect to host."
  elseif code == 22 then
    msg = "HTTP error (e.g., 404 Not Found, 401 Unauthorized)."
  elseif code == 28 then
    msg = "Request timed out."
  else
    msg = "Request failed with unknown exit code: " .. code
  end
  if code ~= 0 then
    vim.notify(msg, vim.log.levels.ERROR)
  end
end

function M.stream_curl(args, handle_prev, handle_response, handle_post)
  local active_job = Job:new {
    command = "curl",
    args = args,
    on_start = handle_prev,
    on_stdout = handle_response,
    on_stderr = handle_response,
    on_exit = handle_post,
  }
  return active_job
end

function M.read_json(path)
  local fd, err, errcode = uv.fs_open(path, "r", default_mod)
  if err or not fd then
    if errcode == "ENOENT" then
      return nil, errcode
    end
    log.error("could not open ", path, ": ", err)
    return nil, errcode
  end

  local stat, err, errcode = uv.fs_fstat(fd)
  if err or not stat then
    uv.fs_close(fd)
    log.error("could not stat ", path, ": ", err)
    return nil, errcode
  end

  local contents, err, errcode = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  if err then
    log.error("could not read ", path, ": ", err)
    return nil, errcode
  end

  local ok, json = pcall(vim.fn.json_decode, contents)
  if not ok then
    log.error("could not parse json in ", path, ": ", err)
    return nil, json
  end

  return json, nil
end

function M.write_json(path, json)
  local ok, text = pcall(vim.fn.json_encode, json)
  if not ok then
    log.error("could not encode JSON ", path, ": ", text)
    return nil, text
  end

  local parent = Path:new(path):parent().filename
  local ok, err = pcall(vim.fn.mkdir, parent, "p")
  if not ok then
    log.error("could not create directory ", parent, ": ", err)
    return nil, err
  end

  local fd, err, errcode = uv.fs_open(path, "w+", default_mod)
  if err or not fd then
    log.error("could not open ", path, ": ", err)
    return nil, errcode
  end

  local size, err, errcode = uv.fs_write(fd, text, 0)
  uv.fs_close(fd)
  if err then
    log.error("could not write ", path, ": ", err)
    return nil, errcode
  end

  return size, nil
end

function M.get_files(dir)
  local files = {}
  local handle, err, _ = uv.fs_scandir(dir)
  if err then
    log.error("could not open ", dir, ": ", err)
    return nil, err
  end
  if handle then
    while true do
      local filename, type = uv.fs_scandir_next(handle)
      if not filename then
        break
      end
      if type == "file" then
        table.insert(files, filename)
      end
    end
    return files
  end
end

function M.rm_file(path)
  local err = nil
  local file = Path:new(path)
  if not file:is_absolute() then
    err = "path is not absolute"
  end
  file:rm(false)
  return err
end

function M.file_is_exist(path)
  return Path:new(path):exists()
end

function M.rename(path, new_name)
  return Path:new(path):rename { new_name = new_name }
end

return M
