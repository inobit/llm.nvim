local M = {}

local ServerManager = require "inobit.llm.server"
local util = require "inobit.llm.util"
local notify = require "inobit.llm.notify"
local win = require "inobit.llm.win"

---@class llm.translate.PromptOptions
---@field output_type string
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
    5. output format: %s]]
  system_prompt = system_prompt:format(params.output_type)
  local content = "translate the following %s statement into %s：'%s'"
  content = content:format(params.source_lang, params.target_lang, params.text:gsub("'", "''"))

  return {
    { role = "system", content = system_prompt },
    { role = ServerManager.translate_server.user_role or "user", content = content },
  }
end

---@param text string
---@return llm.session.Message[]
local function translate_en_to_zh(text)
  return build_translation_prompt {
    output_type = "plain text",
    source_lang = "english",
    target_lang = "simplified chinese",
    text = text,
  }
end

---@param text string
---@return llm.session.Message[]
local function translate_zh_to_en_text(text)
  return build_translation_prompt {
    output_type = "plain text, use natural language, first letter lowercase",
    source_lang = "simplified chinese",
    target_lang = "english",
    text = text,
  }
end

---@param text string
---@return llm.session.Message[]
local function translate_zh_to_en_var_camel(text)
  return build_translation_prompt {
    output_type = "variables in camel case, if the variables character count is greater than 20, then perform reasonable abbreviation.",
    source_lang = "simplified chinese",
    target_lang = "english",
    text = text,
  }
end

---@param text string
---@return llm.session.Message[]
local function translate_zh_to_en_var_underline(text)
  return build_translation_prompt {
    output_type = "variables in underscore naming convention, if the variables character count is greater than 20, then perform reasonable abbreviation.",
    source_lang = "simplified chinese",
    target_lang = "english",
    text = text,
  }
end

---@alias translate_type "E2Z" | "Z2E" | "Z2E_CAMEL" | "Z2E_UNDERLINE"

local types = { "E2Z", "Z2E", "Z2E_CAMEL", "Z2E_UNDERLINE" }

---@param type translate_type
---@return translate_type | nil
function M.is_valid_type(type)
  return vim.iter(types):find(type)
end

---@param type translate_type
---@param text string
---@param callback fun(content: string)
function M.translate(type, text, callback)
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
    messages = translate_en_to_zh(text)
  elseif type == "Z2E" then
    messages = translate_zh_to_en_text(text)
  elseif type == "Z2E_CAMEL" then
    messages = translate_zh_to_en_var_camel(text)
  elseif type == "Z2E_UNDERLINE" then
    messages = translate_zh_to_en_var_underline(text)
  end
  if messages then
    local exit_callback = function(res)
      if res.status == 200 then
        local body = vim.json.decode(res.body)
        callback(body.choices[1].message.content)
        notify.info "Translation completed."
      else
        notify.error(string.format("Translate %s error: %s", res.status, res.body))
      end
    end
    ServerManager.translate_server:request(messages, { stream = false }, nil, exit_callback)
    notify.info "Translating..."
  end
end

---@param content string
local function print_callback(content)
  -- write to "t" register
  -- vim.fn.setreg("t", content)

  local width = math.floor(vim.o.columns * 0.5)
  local height = math.floor(vim.o.lines * 0.2)

  ---@type llm.win.WinConfig
  local opts = {
    width = width,
    height = height,
    row = (vim.o.lines - height) / 2,
    col = (vim.o.columns - width) / 2,
    title = "translate result",
  }

  local floating = win.FloatingWin:new(opts)

  -- register autocmd to clean
  vim.api.nvim_create_autocmd("WinClosed", {
    buffer = floating.bufnr,
    callback = function()
      -- pcall(vim.api.nvim_win_close, winid, true)
      pcall(vim.api.nvim_buf_delete, floating.bufnr, { force = true })
    end,
  })

  -- display content
  vim.api.nvim_buf_set_lines(floating.bufnr, 0, -1, false, vim.iter(vim.gsplit(content, "\n")):totable())
end

---@param replace boolean
---@param type? translate_type
function M.translate_in_buffer(replace, type)
  local text = nil
  local callback = nil
  if vim.api.nvim_get_mode().mode == "n" then
    text = util.get_inner_text()
    callback = replace and util.replace_inner_word or print_callback
  else
    text = util.get_visual_text()
    callback = replace and util.replace_visual_selection or print_callback
  end
  if not type then
    type = util.is_english(text) and "E2Z" or "Z2E"
  end
  M.translate(type, text, vim.schedule_wrap(callback))
end

---@param text string
---@param type? translate_type
function M.translate_in_cmdline(text, type)
  if not type then
    type = util.is_english(text) and "E2Z" or "Z2E"
  end
  M.translate(type, text, vim.schedule_wrap(print_callback))
end

return M
