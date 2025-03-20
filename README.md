# llm.nvim

AI chat, currently supports DeepSeek

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
      { "<leader>ma", "<Cmd>LLM Auth<CR>", desc = "LLM: chat auth" },
      { "<leader>mn", "<Cmd>LLM New<CR>", desc = "LLM: chat new" },
      { "<leader>mx", "<Cmd>LLM Clear<CR>", desc = "LLM: chat clear(unsaved)" },
      { "<leader>mS", "<Cmd>LLM Save<CR>", desc = "LLM: chat  save" },
      { "<leader>ms", "<Cmd>LLM Sessions<CR>", desc = "LLM: select session" },
      { "<leader>md", "<Cmd>LLM Delete<CR>", desc = "LLM: delete session" },
      { "<leader>mr", "<Cmd>LLM Rename<CR>", desc = "LLM: rename session" },
      { "<leader>mv", "<Cmd>LLM Servers<CR>", desc = "LLM: select server" },
      {
        "<leader>ts", function() require("inobit.llm.translate").translate_in_buffer(true)  end, mode = { "n", "v" }, desc = "LLM: translate and replace",
      },
      {
        "<leader>tc", function() require("inobit.llm.translate").translate_in_buffer(true, "Z2E_CAMEL") end, mode = { "n", "v" }, desc = "LLM: translate to VAR_CAMEL",
      },
      {
        "<leader>tu", function() require("inobit.llm.translate").translate_in_buffer(true, "Z2E_UNDERLINE") end, mode = { "n", "v" }, desc = "LLM: translate to VAR_UNDERLINE",
      },
      {
        "<leader>tp", function() require("inobit.llm.translate").translate_in_buffer(false)  end, mode = { "n", "v" }, desc = "LLM: translate and print",
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
{
  servers = {
    {
    server = "DeepSeek"
    base_url = "https://api.deepseek.com/v1/chat/completions",
    model = "deepseek-chat",
    stream = true,
    multi_round = true,
    user_role = "user",
      }
    {
    server = "DeepSeek-SiliconFlow",
    base_url = "https://api.siliconflow.cn/v1/chat/completions",
    model = "deepseek-ai/DeepSeek-V3",
    stream = true,
    multi_round = true,
    user_role = "user",
      }
    },
    default_server = "DeepSeek-SiliconFlow",
    loading_mark = "**Generating response ...**",
    user_prompt = "❯",
    question_hi = { fg = "#1abc9c" },
    base_config_dir = vim.fn.stdpath "cache" .. "/inobit/llm",
    config_dir = "config",
    session_dir = "session",
    config_filename = "config.json",
    chat_win = {
      width_percentage = 0.7,
      response_height_percentage = 0.7,
      input_height_percentage = 0.1,
      winblend = 5,
    },
    session_picker_win = {
      width_percentage = 0.4,
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
```

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
