# llm.nvim

AI chat, currently supports DeepSeek

# Features

- floating chat window
- session manage

# Installation

use lazy.nvim

```lua
return {
  {
    url = "https://gitee.com/inobit/llm.nvim.git"
    dependencies = {
      "nvim-lua/plenary.nvim",
    },
    keys = {
      -- stylua: ignore start
      { "<leader>mm", "<Cmd>LLM Chat<CR>", desc = "LLM: chat start" },
      { "<leader>ma", "<Cmd>LLM Auth<CR>", desc = "LLM: chat auth" },
      { "<leader>mn", "<Cmd>LLM New<CR>", desc = "LLM: chat new" },
      { "<leader>mx", "<Cmd>LLM Clear<CR>", desc = "LLM: chat clear(unsaved)" },
      { "<leader>mS", "<Cmd>LLM Save<CR>", desc = "LLM: chat  save" },
      { "<leader>ms", "<Cmd>LLM Sessions<CR>", desc = "LLM: select session" },
      { "<leader>md", "<Cmd>LLM Delete<CR>", desc = "LLM: delete session" },
      { "<leader>mr", "<Cmd>LLM Rename<CR>", desc = "LLM: rename session" },
      { "<leader>mv", "<Cmd>LLM Servers<CR>", desc = "LLM: select server" },
      -- stylua: ignore end
    },
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
    server = SERVERS.DEEP_SEEK,
    base_url = "https://api.deepseek.com/v1/chat/completions",
    model = "deepseek-chat",
    stream = true,
    multi_round = true,
    user_role = "user",
      }
    },
    default_server = SERVERS.DEEP_SEEK,
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
