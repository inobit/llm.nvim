# llm.nvim

AI chat plugin for Neovim, supporting OpenRouter and any OpenAI-compatible API.

## Features

- Floating or vsplit chat window with markdown rendering support
- Session management (save, load, rename, delete)
- Real-time streaming responses
- Multi-round conversation support
- Multiple AI providers support (OpenRouter, OpenAI, Gemini, Claude, etc.)
- In-buffer translation with auto language detection (Chinese/English)
  - Directly translate and replace in buffer
  - Use `:TS` command to translate and display in floating window
  - Support multiple translation styles:
    - `E2Z`: English to Chinese
    - `Z2E`: Chinese to English
    - `Z2E_CAMEL`: Chinese to English camelCase variable
    - `Z2E_UNDERLINE`: Chinese to English snake_case variable
  ```shell
  :TS [E2Z | Z2E | Z2E_CAMEL | Z2E_UNDERLINE] <text>
  ```

## Requirements

- Neovim >= 0.10.0
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) (required)
- API key for your chosen provider (see below)

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
return {
  "inobit/llm.nvim",
  dependencies = { "nvim-lua/plenary.nvim" },
  main = "inobit/llm",
  opts = {}
}
```

## Setup

### 1. Set API Key

The plugin uses the default OpenRouter configuration. Set your API key:

```shell
export OPENROUTER_API_KEY="your-api-key"
```

Or in your Neovim config:

```lua
vim.fn.setenv("OPENROUTER_API_KEY", "your-api-key")
```

## Configuration

The plugin works out of the box with sensible defaults. To customize, pass options to the setup function:

```lua
{
  "inobit/llm.nvim",
  dependencies = { "nvim-lua/plenary.nvim" },
  main = "inobit/llm",
  -- Optional: custom keymaps
  keys = {
    { "<leader>mc", "<Cmd>LLM Chat<CR>", desc = "LLM: chat start" },
    { "<leader>ms", "<Cmd>LLM Sessions<CR>", desc = "LLM: select session" },
    { "<leader>mv", "<Cmd>LLM ChatServers<CR>", desc = "LLM: select chat server" },
    { "<leader>mt", "<Cmd>LLM TSServers<CR>", desc = "LLM: select translate server" },
    { "<leader>ts", function() require("inobit.llm.api").translate_in_buffer(true) end, mode = { "n", "v" }, desc = "LLM: translate and replace" },
    { "<leader>tc", function() require("inobit.llm.api").translate_in_buffer(true, "Z2E_CAMEL") end, mode = { "n", "v" }, desc = "LLM: translate to VAR_CAMEL" },
    { "<leader>tu", function() require("inobit.llm.api").translate_in_buffer(true, "Z2E_UNDERLINE") end, mode = { "n", "v" }, desc = "LLM: translate to VAR_UNDERLINE" },
    { "<leader>tp", function() require("inobit.llm.api").translate_in_buffer(false) end, mode = { "n", "v" }, desc = "LLM: translate and print" },
  },
  opts = {
    -- Default server@model to use (format: "ServerName@model-name")
    default_server = "OpenRouter@openai/gpt-4.5",

    -- Default server for translation tasks
    -- default_translate_server = "OpenRouter@google/gemini-2.5-flash",

    -- Chat window layout: "float" (default) or "vsplit"
    chat_layout = "float",

    -- Vsplit window configuration (when chat_layout = "vsplit")
    vsplit_win = {
      width_percentage = 0.45,  -- Width of the chat panel (0.2 - 0.7)
    },
    servers = {
      -- Example: Add more OpenRouter models
      {
        server = "OpenRouter",
        server_type = "chat",
        base_url = "https://openrouter.ai/api/v1/chat/completions",
        api_key_name = "OPENROUTER_API_KEY",
        stream = true,
        multi_round = true,
        max_tokens = 4096,
        user_role = "user",
        models = {
          { model = "anthropic/claude-opus-4", temperature = 0.4 },
          { model = "anthropic/claude-sonnet-4", temperature = 0.4 },
          { model = "openai/gpt-4.5", temperature = 0.4 },
          { model = "openai/gpt-4o", temperature = 0.4 },
          { model = "google/gemini-2.5-flash", max_tokens = 8192, temperature = 0.6 },
          { model = "google/gemini-3-pro", max_tokens = 8192, temperature = 0.4 },
        },
      },

      -- Example: Add translation server (DeepL/DeepLX)
      {
        server = "DeepL",
        server_type = "translate",
        models = {
          {
            model = "DeepLX",
            base_url = "http://localhost:1188/translate", -- Self-hosted DeepLX
            api_key_name = "DEEPLX_API_KEY",
          },
        },
      },
    },
  },
}
```

## Default Configuration

```lua
-- lua/inobit/llm/config.lua

local function default_servers()
  return {
    {
      server = "OpenRouter",
      server_type = "chat",
      base_url = "https://openrouter.ai/api/v1/chat/completions",
      api_key_name = "OPENROUTER_API_KEY",
      stream = true,
      multi_round = true,
      max_tokens = 4096,
      user_role = "user",
      models = {
        { model = "anthropic/claude-opus-4", temperature = 0.4 },
        { model = "openai/gpt-4.5", temperature = 0.4 },
        { model = "google/gemini-3-pro", max_tokens = 8192, temperature = 0.4 },
      },
    },
  }
end

function M.defaults()
  return {
    default_server = "OpenRouter@openai/gpt-4.5",
    chat_layout = "float",
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
    vsplit_win = {
      width_percentage = 0.45,
    },
  }
end
```

## Usage

### Commands

| Command            | Description                         |
| ------------------ | ----------------------------------- |
| `:LLM Chat`        | Start a new chat session            |
| `:LLM Sessions`    | Select and manage existing sessions |
| `:LLM ChatServers` | Select chat server (model)          |
| `:LLM TSServers`   | Select translation server           |

### Chat Window Keymaps

| Key     | Action               |
| ------- | -------------------- |
| `<C-C>` | End current session  |
| `<C-S>` | Save current session |
| `<C-N>` | Create new session   |

### Session Picker Keymaps

| Key | Action         |
| --- | -------------- |
| `r` | Rename session |
| `d` | Delete session |

## Integration

### render-markdown

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
    render_modes = true,
    code = {
      sign = false,
      width = "full",
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

### lualine

```lua
lualine_x = {
  -- stylua: ignore start
  {
    function() return "󰗊 "..  require("inobit.llm.api").is_translating() end,
    cond = function() return package.loaded["inobit.llm"] and require("inobit.llm.api").is_translating() ~= nil end,
    color = function() return { fg = string.format("#%06x", vim.api.nvim_get_hl(0, { name = "Debug", link = false }).fg) } end,
  },
  {
    function() return "󰅾 " .. require("inobit.llm.api"):has_active_chats() .. "/" .. require("inobit.llm.api"):has_chats() end,
    cond = function() return package.loaded["inobit.llm"] and require("inobit.llm.api"):has_chats() > 0 end,
    color = function() return { fg = string.format("#%06x", vim.api.nvim_get_hl(0, { name = "DiagnosticHint", link = false }).fg) } end,
  },
  -- stylua: ignore end
}
```

## License

MIT
