local M = {}

local servers = require "inobit.llm.servers"
local util = require "inobit.llm.util"
local curl = require "plenary.curl"
local notify = require "inobit.llm.notify"

-- translate
local function build_translation_prompt(params)
  local system_prompt = [[
        作为专业语言处理引擎，执行精确的文本翻译任务。请将源语言内容准确转换为目标语言。
        翻译要求：
        1. 保持原文语义完整性
        2. 符合目标语言语法规范
        3. 保留专业术语原意
        4. 仅输出结果（不带任何注释）
        5. 输出格式：%s]]
  system_prompt = system_prompt:format(params.output_type)
  local content = "将以下%s语句翻译为%s：'%s'"
  content = content:format(params.source_lang, params.target_lang, params.text:gsub("'", "''"))

  return {
    { role = "system", content = system_prompt },
    { role = servers.get_server_selected().user_role, content = content },
  }
end

local function translate_en_to_zh(text)
  return build_translation_prompt {
    output_type = "纯文本",
    source_lang = "英语",
    target_lang = "简体中文",
    text = text,
  }
end

local function translate_zh_to_en_text(text)
  return build_translation_prompt {
    output_type = "纯文本(使用自然语言,首字母小写)",
    source_lang = "简体中文",
    target_lang = "英语",
    text = text,
  }
end

local function translate_zh_to_en_var_camel(text)
  return build_translation_prompt {
    output_type = "驼峰命名形式的变量(如果超过20个字符则进行合理的简写)",
    source_lang = "简体中文",
    target_lang = "英语",
    text = text,
  }
end

local function translate_zh_to_en_var_underline(text)
  return build_translation_prompt {
    output_type = "下划线命名形式的变量(如果超过20个字符则进行合理的简写)",
    source_lang = "简体中文",
    target_lang = "英语",
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

return M
