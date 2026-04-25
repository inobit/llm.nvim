---@diagnostic disable: redefined-local
local log = require "inobit.llm.log"
local Path = require "plenary.path"
local uv = vim.uv or vim.loop
local default_mod = 438 --0666

local M = {}

---Read and parse a JSON file
---@param path string The path to the JSON file
---@return unknown? data Parsed JSON data, or nil on failure
---@return string? err Error code if failed ("ENOENT" for missing file, or other error)
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

---Write data to a JSON file
---@param path string The path to the JSON file
---@param json unknown The data to encode and write
---@return integer? size Number of bytes written on success
---@return string? err Error message if failed
function M.write_json(path, json)
  local ok, text = pcall(vim.fn.json_encode, json)
  if not ok then
    log.error("could not encode JSON ", path, ": ", text)
    return nil, text
  end

  local parent = Path:new(path):parent().filename
  local ok, result = pcall(vim.fn.mkdir, parent, "p")
  if not ok then
    ---@cast result -integer
    log.error("could not create directory ", parent, ": ", result)
    return nil, result
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

---Get list of files in a directory
---@param dir string The directory path to scan
---@return string[]? files List of filenames, or nil on failure
---@return string? err Error message if failed
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

---Remove a file
---@param path string The absolute path to the file to remove
---@return string? err Error message if path is not absolute, nil on success
function M.rm_file(path)
  local err = nil
  local file = Path:new(path)
  if not file:is_absolute() then
    err = "path is not absolute"
  end
  file:rm(false)
  return err
end

---Check if a file exists
---@param path string The path to check
---@return boolean exists True if the file exists, false otherwise
function M.file_is_exist(path)
  return Path:new(path):exists()
end

---Rename a file or directory
---@param path string The current path
---@param new_name string The new name/path
---@return Path? result The renamed Path object on success
---@return string? err Error message on failure
function M.rename(path, new_name)
  return Path:new(path):rename { new_name = new_name }
end

return M
