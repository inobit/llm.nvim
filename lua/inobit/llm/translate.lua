local M = {}

local servers = require "inobit.llm.servers"
local util = require "inobit.llm.util"
local curl = require "plenary.curl"
local notify = require "inobit.llm.notify"
local win = require "inobit.llm.win"

-- translate
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
    { role = servers.get_server_selected().user_role, content = content },
  }
end

local function translate_en_to_zh(text)
  return build_translation_prompt {
    output_type = "plain text",
    source_lang = "english",
    target_lang = "simplified chinese",
    text = text,
  }
end

local function translate_zh_to_en_text(text)
  return build_translation_prompt {
    output_type = "plain text, use natural language, first letter lowercase",
    source_lang = "simplified chinese",
    target_lang = "english",
    text = text,
  }
end

local function translate_zh_to_en_var_camel(text)
  return build_translation_prompt {
    output_type = "variables in camel case, if the variables character count is greater than 20, then perform reasonable abbreviation.",
    source_lang = "simplified chinese",
    target_lang = "english",
    text = text,
  }
end

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

  -- check server
  local check = servers.check_options(servers.get_server_selected().server)
  if not check then
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
  local url, opts = servers.get_server_selected().build_curl_request(messages, { stream = false })
  opts.callback = function(res)
    if res.status == 200 then
      local body = vim.json.decode(res.body)
      callback(body.choices[1].message.content)
    else
      vim.schedule(function()
        notify.error(string.format("Translate %s error: %s", res.status, res.body))
      end)
    end
  end
  curl.post(url, opts) -- async when stream or callback is exsit
end

---@param type translate_type
function M.translate_and_repalce(type)
  if vim.api.nvim_get_mode().mode == "n" then
    M.translate(type, util.get_inner_text(), vim.schedule_wrap(util.replace_inner_word))
  else
    M.translate(type, util.get_visual_text(), vim.schedule_wrap(util.replace_visual_selection))
  end
end

---@param content string
function M.print_callback(content)
  -- write to "t" register
  -- vim.fn.setreg("t", content)

  -- create floating window
  local width = math.floor(vim.o.columns * 0.5)
  local height = math.floor(vim.o.lines * 0.2)
  local left = (vim.o.columns - width) / 2
  local top = (vim.o.lines - height) / 2
  ---@diagnostic disable-next-line: unused-local
  local bufnr, winid = win.create_floating_window(width, height, top, left, 0, "translate result")

  -- register autocmd to clean
  vim.api.nvim_create_autocmd("WinClosed", {
    buffer = bufnr,
    callback = function()
      -- pcall(vim.api.nvim_win_close, winid, true)
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end,
  })

  -- display content
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.iter(vim.gsplit(content, "\n")):totable())
end

---@param type translate_type
function M.translate_and_print(type)
  if vim.api.nvim_get_mode().mode == "n" then
    M.translate(type, util.get_inner_text(), vim.schedule_wrap(M.print_callback))
  else
    M.translate(type, util.get_visual_text(), vim.schedule_wrap(M.print_callback))
  end
end

return M
