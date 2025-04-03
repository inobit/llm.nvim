# llm.nvim

AI chat, currently supports OpenAI API

# Features

- floating chat window
- session manage
- translate
  one can directly translate and replace in the buffer, or use the TS command to translate the specified content(the result will be displayed in a floating window).
  can automatically detect language(chinese or english)
  ```shell
  :TS [ E2Z | Z2E | Z2E_CAMEL | Z2E_UNDERLINE ] <text>
  ```

# Installation

use lazy.nvim

```lua
return {
  {
    url = "https://gitee.com/inobit/llm.nvim.git",
    dependencies = {
      "nvim-lua/plenary.nvim",
    },
    keys = {
      -- stylua: ignore start
      { "<leader>mc", "<Cmd>LLM Chat<CR>", desc = "LLM: chat start" },
      { "<leader>ms", "<Cmd>LLM Sessions<CR>", desc = "LLM: select session" },
      { "<leader>mv", "<Cmd>LLM ChatServers<CR>", desc = "LLM: select chat server" },
      { "<leader>mt", "<Cmd>LLM TSServers<CR>", desc = "LLM: select translate server" },
      {
        "<leader>ts", function() require("inobit.llm.api").translate_in_buffer(true)  end, mode = { "n", "v" }, desc = "LLM: translate and replace",
      },
      {
        "<leader>tc", function() require("inobit.llm.api").translate_in_buffer(true, "Z2E_CAMEL") end, mode = { "n", "v" }, desc = "LLM: translate to VAR_CAMEL",
      },
      {
        "<leader>tu", function() require("inobit.llm.api").translate_in_buffer(true, "Z2E_UNDERLINE") end, mode = { "n", "v" }, desc = "LLM: translate to VAR_UNDERLINE",
      },
      {
        "<leader>tp", function() require("inobit.llm.api").translate_in_buffer(false)  end, mode = { "n", "v" }, desc = "LLM: translate and print",
      },
      -- stylua: ignore end
    },
    cmd = { "LLM", "TS" },
    main = "inobit/llm",
    -- your config
    opts = {},
  },
}
```

# Default Config

```lua
-- lua/inobit/llm/config.lua

local function default_servers()
  return {
    {
      server = "DeepSeek",
      base_url = "https://api.deepseek.com/v1/chat/completions",
      api_key_name = "DEEPSEEK_API_KEY",
      stream = true,
      multi_round = true,
      user_role = "user",
      models = { "deepseek-chat", "deepseek-reasoner" },
    },
    {
      server = "SiliconFlow",
      base_url = "https://api.siliconflow.cn/v1/chat/completions",
      api_key_name = "SILICONFLOW_API_KEY",
      stream = true,
      multi_round = true,
      user_role = "user",
      models = { "deepseek-ai/DeepSeek-V3", "deepseek-ai/DeepSeek-R1" },
    },
  }
end

function M.defaults()
  return {
    -- server@model
    default_server = "SiliconFlow@deepseek-ai/DeepSeek-V3",
    loading_mark = "**Generating response ...**",
    user_prompt = "❯",
    question_hi = { fg = "#1abc9c" },
    data_dir = vim.fn.stdpath "cache" .. "/inobit/llm",
    session_dir = "session",
    chat_win = {
      width_percentage = 0.7,
      content_height_percentage = 0.7,
      input_height_percentage = 0.1,
      winblend = 3,
    },
    session_picker_win = {
      width_percentage = 0.5,
      input_height = 1,
      content_height_percentage = 0.3,
      winblend = 5,
    },
    server_picker_win = {
      width_percentage = 0.3,
      input_height = 1,
      content_height_percentage = 0.2,
      winblend = 5,
    },
  }
end
```

# Usage

```shell
:LLM Start # start chat
:LLM Sessions # select session
:LLM ChatServers # select chat server
:LLM TSServers # selcect translate server
```

`<C-C>` end session in chat window
`<C-S>` save session in chat window
`<C-N>` create new session in chat window
`r` rename session in session picker window
`d` delete session in session picker window

# Integration

You can use the [render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim) plugin to render the AI's response.

Set the following in your options file:

```lua
vim.g.inobit_filetype = "inobit"
```

Register treesitter in file `after/ftplugin/inobit.lua`:

```lua
vim.treesitter.language.register("markdown", vim.g.inobit_filetype)
```

Configure `render-markdown`:

> [!Note] Alone or as a dependency.

```lua

return {
  "MeanderingProgrammer/render-markdown.nvim",
  dependencies = {
    "nvim-treesitter/nvim-treesitter",
    "nvim-tree/nvim-web-devicons",
  }, -- if you prefer nvim-web-devicons
  opts = {
    -- Vim modes that will show a rendered view of the markdown file
    -- All other modes will be unaffected by this plugin
    -- render_modes = { "n", "c" },
    render_modes = true,
    code = {
      sign = false,
      width = "full",
      -- right_pad = 1,
    },
    heading = {
      sign = false,
      icons = {},
    },
    html = {
      enabled = true,
      comment = { conceal = false },
    },
  },
  ft = { "markdown", "norg", "rmd", "org", vim.g.inobit_filetype },
}
```
