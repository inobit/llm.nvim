local M = {}

local ServerManager = require "inobit.llm.server"
local util = require "inobit.llm.util"
local notify = require "inobit.llm.notify"
local win = require "inobit.llm.win"
local Spinner = require("inobit.llm.spinner").TextSpinner

---@class llm.translate.PromptOptions
---@field output_content string
---@field output_format string
---@field source_lang string
---@field target_lang string
---@field text string

---build translation prompt
---@param params llm.translate.PromptOptions
---@return llm.session.Message[]
local function build_translation_prompt(params)
  local system_prompt = [[
    As a professional language processing engine, perform precise text translation tasks. please accurately convert the source language content to the target language. translation requirements: 
    1. maintain the semantic integrity of the original text. 
    2. comply with the grammatical norms of the target language. 
    3. retain the original meaning of professional terms. 
    4. output the result only (without any comments). 
    5. output content: %s
    6. output format: %s]]
  system_prompt = system_prompt:format(params.output_content, params.output_format)
  local content = "translate the following %s statement into %s：'%s'"
  content = content:format(params.source_lang, params.target_lang, params.text:gsub("'", "''"))

  return {
    { role = "system", content = system_prompt },
    { role = ServerManager.translate_server.user_role or "user", content = content },
  }
end

---@param text string
---@param format translate_format
---@return llm.session.Message[]
local function translate_en_to_zh(text, format)
  return build_translation_prompt {
    output_content = format == "complex"
        and "plain text,use natural language,first letter lowercase,and American and British phonetic symbols"
      or "plain text,use natural language,first letter lowercase",
    output_format = format == "complex" and "美/phonetic/ \n 英/phonetic/ \n plain text" or "plain text",
    source_lang = "english",
    target_lang = "simplified chinese",
    text = text,
  }
end

---@param text string
---@param format translate_format
---@return llm.session.Message[]
local function translate_zh_to_en_text(text, format)
  return build_translation_prompt {
    output_content = format == "complex"
        and "plain text,use natural language,first letter lowercase,and American and British phonetic symbols"
      or "plain text,use natural language,first letter lowercase",
    output_format = format == "complex" and "美/phonetic/ \n 英/phonetic/ \n plain text" or "plain text",
    source_lang = "simplified chinese",
    target_lang = "english",
    text = text,
  }
end

---@param text string
---@return llm.session.Message[]
local function translate_zh_to_en_var_camel(text)
  return build_translation_prompt {
    output_content = "variables in camel case, if the variables character count is greater than 20, then perform reasonable abbreviation.",
    output_format = "plain text",
    source_lang = "simplified chinese",
    target_lang = "english",
    text = text,
  }
end

---@param text string
---@return llm.session.Message[]
local function translate_zh_to_en_var_underline(text)
  return build_translation_prompt {
    output_content = "variables in underscore naming convention, if the variables character count is greater than 20, then perform reasonable abbreviation.",
    output_format = "plain text",
    source_lang = "simplified chinese",
    target_lang = "english",
    text = text,
  }
end

---@alias translate_format "complex" | "simple"
---@alias text_from "buffer" | "cmdline
---@alias translate_type "E2Z" | "Z2E" | "Z2E_CAMEL" | "Z2E_UNDERLINE"

local types = { "E2Z", "Z2E", "Z2E_CAMEL", "Z2E_UNDERLINE" }

---@param type translate_type
---@return translate_type | nil
function M.is_valid_type(type)
  return vim.iter(types):find(type)
end

local translate_status = { value = nil }
-- singleton
local spinner = Spinner:new(translate_status, { ".  ", ".. ", "..." }, 300)
---@return string | nil
function M.get_translate_status()
  return translate_status.value
end

---@param type translate_type
---@param format translate_format
---@param from text_from
---@param text string
---@param callback fun(content: string,from?: text_from)
function M.translate(type, format, from, text, callback)
  -- check text
  if util.empty_str(text) then
    return
  end

  -- check type
  if not vim.iter(types):find(type) then
    notify.error "Invalid type"
    return
  end

  local messages = nil
  if type == "E2Z" then
    messages = translate_en_to_zh(text, format)
  elseif type == "Z2E" then
    messages = translate_zh_to_en_text(text, format)
  elseif type == "Z2E_CAMEL" then
    messages = translate_zh_to_en_var_camel(text)
  elseif type == "Z2E_UNDERLINE" then
    messages = translate_zh_to_en_var_underline(text)
  end
  if messages then
    local exit_callback = function(res)
      if res.status == 200 then
        local body = vim.json.decode(res.body)
        callback(body.choices[1].message.content, from)
      else
        notify.error(string.format("Translate %s error: %s", res.status, res.body))
      end
      spinner:stop()
    end
    ServerManager.translate_server:request(messages, { stream = false, temperature = 1.3 }, nil, exit_callback)
    spinner:start()
  end
end

---@param content string
---@param from text_from
local function hover_result(content, from)
  local lines = vim.split(content, "\n")
  local width = 0
  local height = 0
  local max_width = math.floor(vim.o.columns * 0.5)
  local min_width = math.floor(vim.o.columns * 0.1)
  vim.iter(lines):each(function(line)
    local line_width = math.max(vim.fn.strdisplaywidth(line), min_width)
    if line_width > max_width then
      height = height + math.ceil(line_width / max_width)
      line_width = max_width
    else
      height = height + 1
    end
    width = math.max(width, line_width)
  end)

  table.insert(lines, "")
  table.insert(lines, 1, "")
  height = math.min(math.floor(vim.o.lines * 0.5), height + 2)

  local independent_opts
  if from == "buffer" then
    local c_row, c_col = unpack(vim.api.nvim_win_get_cursor(0))
    local v, h
    local row = 1
    if c_row > math.floor(vim.o.lines * 0.5) then
      v = "S"
      row = 0
    else
      v = "N"
    end
    if c_col > math.floor(vim.o.columns * 0.5) then
      h = "E"
    else
      h = "W"
    end
    independent_opts = { relative = "cursor", row = row, col = 0, anchor = v .. h }
  else
    -- from cmdline
    independent_opts = {
      relative = "editor",
      row = (vim.o.lines - height) / 2,
      col = (vim.o.columns - width) / 2,
      border = "single",
    }
  end

  ---@type llm.win.WinConfig
  local opts = vim.tbl_extend("force", {
    width = width,
    height = height,
    style = "minimal",
    border = "none",
    focusable = true,
  }, independent_opts)

  local floating = win.FloatingWin:new(opts)

  vim.api.nvim_create_autocmd("cursormoved", {
    group = vim.api.nvim_create_augroup("llm_ts_clean_float", { clear = true }),
    buffer = vim.api.nvim_get_current_buf(),
    callback = function()
      floating:close()
      pcall(vim.api.nvim_buf_delete, floating.bufnr, { force = true })
    end,
  })

  -- display content
  vim.api.nvim_buf_set_lines(floating.bufnr, 0, -1, false, lines)
end

---@param replace boolean
---@param type translate_type
---@param text string
---@return translate_format
local function detect_format(replace, type, text)
  local format = "simple"
  if not replace and type ~= "Z2E_CAMEL" and type ~= "Z2E_UNDERLINE" then
    --WARN: don't support UTF-8
    local punctuation_pattern = "[,.!?;:，。！？；：]"
    if not string.find(text, punctuation_pattern) then
      format = "complex"
    end
  end
  return format
end

---@param replace boolean
---@param type? translate_type
function M.translate_in_buffer(replace, type)
  local text = nil
  local callback = nil
  if vim.api.nvim_get_mode().mode == "n" then
    text = util.get_inner_text()
    callback = replace and util.replace_inner_word or hover_result
  else
    text = util.get_visual_text()
    callback = replace and util.replace_visual_selection or hover_result
  end
  if not type then
    type = util.is_english(text) and "E2Z" or "Z2E"
  end
  text = vim.trim(text)
  M.translate(type, detect_format(replace, type, text), "buffer", text, vim.schedule_wrap(callback))
end

---@param text string
---@param type? translate_type
function M.translate_in_cmdline(text, type)
  if not type then
    type = util.is_english(text) and "E2Z" or "Z2E"
  end
  text = vim.trim(text)
  M.translate(type, detect_format(false, type, text), "cmdline", text, vim.schedule_wrap(hover_result))
end

--TODO: lualine spinner

return M
