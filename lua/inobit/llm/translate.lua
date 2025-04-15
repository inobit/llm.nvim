local M = {}

local ServerManager = require "inobit.llm.server"
local util = require "inobit.llm.util"
local notify = require "inobit.llm.notify"
local win = require "inobit.llm.win"
local Spinner = require("inobit.llm.spinner").TextSpinner

---@class llm.translate.PromptOptions
---@field task_specification string
---@field format_requirements string
---@field source_lang string
---@field target_lang string
---@field text string

---build translation prompt
---@param params llm.translate.PromptOptions
---@return llm.session.Message[]
local function build_translation_prompt(params)
  local system_prompt = [[
    ### Translation Specialist Guidelines
    
    **Core Principles**
    1. Semantic Preservation: Maintain original meaning integrity
    2. Grammatical Accuracy: Strictly follow target language norms
    3. Terminology Consistency: Preserve domain-specific terms
    
    **Task Specification**
    %s
    
    **Format Requirements**
    %s
    
    **Style Constraints**
    - Prohibit markdown/formatting symbols
    - Exclude explanatory notes
    - Avoid emoji/special characters
    - Strictly use requested casing
    
    **Output Validation**
    1. Check semantic equivalence
    2. Verify terminology consistency
    3. Ensure format compliance]]
  system_prompt = system_prompt:format(params.task_specification, params.format_requirements)
  local content = "translate the following %s statement into %s：'%s'"
  content = content:format(params.source_lang, params.target_lang, params.text:gsub("'", "''"))

  return {
    { role = "system", content = system_prompt },
    { role = ServerManager.translate_server.user_role or "user", content = content },
  }
end

---@param text string
---@param specification translate_specification
---@return llm.session.Message[]
local function translate_en_to_zh(text, specification)
  return build_translation_prompt {
    task_specification = specification == "complex" and [[
    **Phonetic Requirements**
    - Include US/UK IPA transcriptions
    - Format phonetics between /slashes/
    - Prioritize primary stress markers
    
    Example:
    "Hello" → 美/həˈloʊ/ 英/hɛˈləʊ/]] or "Natural language output",
    format_requirements = specification == "complex" and [[
    **Structured Output Format**
    美: /.../
    英: /.../ 
    (Translation plain text)]] or [[
    **Format Constraints**
    1. No markdown/formatting symbols
    2. Avoid ellipsis(...) truncation]],
    source_lang = "english",
    target_lang = "simplified chinese",
    text = text,
  }
end

---@param text string
---@param specification translate_specification
---@return llm.session.Message[]
local function translate_zh_to_en_text(text, specification)
  return build_translation_prompt {
    task_specification = specification == "complex" and [[
    **Phonetic Requirements**
    - Include US/UK IPA transcriptions
    - Format phonetics between /slashes/
    - Prioritize primary stress markers
    
    Example:
    "Hello" → 美/həˈloʊ/ 英/hɛˈləʊ/]] or "Natural language output with lowercase initial letter",
    format_requirements = specification == "complex" and [[
    **Structured Output Format**
    美: /.../
    英: /.../ 
    (Translation plain text)]] or [[
    **Format Constraints**
    1. No markdown/formatting symbols
    2. Lowercase initial letter (except proper nouns)
    3. Avoid ellipsis(...) truncation]],
    source_lang = "simplified chinese",
    target_lang = "english",
    text = text,
  }
end

---@param text string
---@return llm.session.Message[]
local function translate_zh_to_en_var_camel(text)
  return build_translation_prompt {
    task_specification = [[
    **CamelCase Conversion Rules**
    1. Word Segmentation: Split using NLP tokenization
    2. Connector Handling: Remove all spaces、-、_
    3. Capitalization:
       - First word lowercase
       - Subsequent words capitalized
    4. Abbreviation Logic:
       | Length   | Strategy                   | Example                |
       |----------|----------------------------|------------------------|
       | ≤20 chars| Full words                 | 用户权限 → userPermission |
       | >20 chars| Per-word first 3 letters*  | 分布式事务处理系统 → distTransProcSys |
    5. Exclusion Rules:
       - Remove articles (a/an/the)
       - Remove auxiliary verbs (is/are)
    6. Edge Cases:
       - Mixed languages → "User权限" → userAuth
       - Acronyms → "API网关" → apiGateway
       - Numbers → "版本2" → version2]],
    format_requirements = "Translation plain text",
    source_lang = "simplified chinese",
    target_lang = "english",
    text = text,
  }
end

---@param text string
---@return llm.session.Message[]
local function translate_zh_to_en_var_underline(text)
  return build_translation_prompt {
    task_specification = [[
    **Snake_case Conversion Rules**
    1. Delimiter: _ between semantic units
    2. Case Policy: Strict lowercase
    3. Abbreviation Matrix:
       | Condition              | Strategy                  | Example                |
       |------------------------|---------------------------|------------------------|
       | Total length ≤20 chars | Full words                | 用户配置 → user_config     |
       | Total length >20 chars | Compress per-word (see below) |
    4. Per-word Compression:
       - Keep first 3 consonants
       - Remove vowels after 3rd letter
       - Exceptions:
         * 4-letter words → first 3 letters
         * Proper nouns → first 4 letters
    5. Edge Case Handling:
       - Numbers → "版本2" → ver2
       - Mixed case → "userConfig" → user_config
       - Consecutive vowels → "管理员" → mgmt
    6. Validation:
       - No consecutive underscores
       - Final length ≤32 chars]],
    format_requirements = "Translation plain text",
    source_lang = "simplified chinese",
    target_lang = "english",
    text = text,
  }
end

---@alias translate_specification "complex" | "simple"
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

---@param s string
---@param t translate_type
---@return string
local function convert_to_variable(s, t)
  if t == "Z2E_CAMEL" then
    return util.simpleVariableConverter(s, "camel")
  elseif t == "Z2E_UNDERLINE" then
    return util.simpleVariableConverter(s, "underline")
  else
    return s
  end
end

---@param translate_type translate_type
---@param specification translate_specification
---@param from text_from
---@param text string
---@param callback fun(content: string,from?: text_from)
function M.translate(translate_type, specification, from, text, callback)
  -- check text
  if util.empty_str(text) then
    return
  end

  -- check type
  if not vim.iter(types):find(translate_type) then
    notify.error "Invalid type"
    return
  end

  local server = ServerManager.translate_server --[[@as llm.OpenAIServer | llm.DeepLServer]]
  local messages = {}
  local opts = {}

  if server:is_chat_server() then
    if translate_type == "E2Z" then
      messages = translate_en_to_zh(text, specification)
    elseif translate_type == "Z2E" then
      messages = translate_zh_to_en_text(text, specification)
    elseif translate_type == "Z2E_CAMEL" then
      messages = translate_zh_to_en_var_camel(text)
    elseif translate_type == "Z2E_UNDERLINE" then
      messages = translate_zh_to_en_var_underline(text)
    end
    opts = server:build_request_opts(messages, { stream = false, temperature = 1.3 })
  elseif server:is_translate_server() then
    messages.text = server.clean_source_text and server:clean_source_text(text) or text
    if vim.startswith(translate_type, "E2Z") then
      messages.target_lang = "ZH"
    elseif vim.startswith(translate_type, "Z2E") then
      messages.target_lang = "EN"
    end
    opts = server--[[@as llm.DeepLServer]]:build_request_opts(messages)
  else
    notify.error(string.format("Server %s not supported", server))
    return
  end

  local exit_callback = function(res)
    if res.status == 200 then
      local result = server:parse_translation_result(res)
      if type(result) == "table" then
        if specification == "simple" or result.alternatives == nil or #result.alternatives == 0 then
          result = result.data
        else
          local style = { result.data, "备选:" }
          result.alternatives = vim.tbl_map(function(str)
            return "- " .. str
          end, result.alternatives)
          vim.list_extend(style, result.alternatives)
          result = table.concat(style, "\n")
        end
      end
      callback(convert_to_variable(result --[[@as string]], translate_type), from)
    else
      notify.error(string.format("Translate %s error: %s", res.status, res.body))
    end
    spinner:stop()
  end
  opts.callback = exit_callback
  ServerManager.translate_server:request(opts)
  spinner:start()
end

---@param content string
---@param from text_from
local function hover_result(content, from)
  local padding = 1
  local lines = vim.split(content, "\n")
  local width = 0
  local height = 0
  local max_width = math.floor(vim.o.columns * 0.5) - 2
  vim.iter(lines):each(function(line)
    local line_width = vim.fn.strdisplaywidth(line)
    if line_width > max_width then
      height = height + math.ceil(line_width / max_width)
      line_width = max_width
    else
      height = height + 1
    end
    width = math.max(width, line_width)
  end)

  height = math.min(math.floor(vim.o.lines * 0.5) - 2, height)

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
    width = width + 2,
    height = height + 2,
    style = "minimal",
    border = "none",
    focusable = true,
  }, independent_opts)

  local floating = win.PaddingFloatingWin:new(opts, padding)
  vim.bo[floating.bufnr].filetype = vim.g.inobit_filetype

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
---@param text string
---@return translate_specification
local function detect_format(replace, text)
  local format = "simple"
  if not replace then
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
  M.translate(type, detect_format(replace, text), "buffer", text, vim.schedule_wrap(callback))
end

---@param text string
---@param type? translate_type
function M.translate_in_cmdline(text, type)
  if not type then
    type = util.is_english(text) and "E2Z" or "Z2E"
  end
  text = vim.trim(text)
  M.translate(type, detect_format(false, text), "cmdline", text, vim.schedule_wrap(hover_result))
end

return M
