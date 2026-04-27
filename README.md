# llm.nvim

AI chat plugin for Neovim, supporting OpenRouter and any OpenAI-compatible API.

## Features

- Floating or vsplit chat window with markdown rendering support
- Session management (save, load, rename, delete)
- Real-time streaming responses
- Multi-round conversation support
- **Retry functionality**: Press `r` on any user message to retry the question
- Multiple AI providers support (OpenRouter, OpenAI, Gemini, Claude, etc.)
- **Dynamic Model Fetching**: Automatically fetch available models from provider APIs with caching
- **Layered Provider Selection**: Two-panel picker for Provider → Model selection workflow
  - Auto-detects context: changes current chat's model if foreground, otherwise sets default
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

The plugin works out of the box with sensible defaults. To customize, pass options to the setup function.

### Configuration Example

```lua
return {
  "inobit/llm.nvim",
  dependencies = { "nvim-lua/plenary.nvim" },
  main = "inobit/llm",
  cmd = { "LLM", "TS" },
  keys = {
    -- stylua: ignore start
    { "<leader>at", "<Cmd>LLM Toggle<CR>", desc = "LLM: chat toggle" },
    { "<leader>as", "<Cmd>LLM Sessions<CR>", desc = "LLM: select session" },
    { "<leader>ap", "<Cmd>LLM ChatProviders<CR>", desc = "LLM: select chat provider" },
    { "<leader>aP", "<Cmd>LLM TSProviders<CR>", desc = "LLM: select translate provider" },
    {
      "<leader>ts", function() require("inobit.llm.api").translate_in_buffer(true) end,
      mode = { "n", "v" }, desc = "LLM: translate and replace",
    },
    {
      "<leader>tc", function() require("inobit.llm.api").translate_in_buffer(true, "Z2E_CAMEL") end,
      mode = { "n", "v" }, desc = "LLM: translate to VAR_CAMEL",
    },
    {
      "<leader>tu", function() require("inobit.llm.api").translate_in_buffer(true, "Z2E_UNDERLINE") end,
      mode = { "n", "v" }, desc = "LLM: translate to VAR_UNDERLINE",
    },
    {
      "<leader>tp", function() require("inobit.llm.api").translate_in_buffer(false) end,
      mode = { "n", "v" }, desc = "LLM: translate and print",
    },
    -- stylua: ignore end
  },
  opts = {
    -- Default provider to use (provider name only)
    default_provider = "OpenRouter",
    -- Default provider for translation tasks (optional, defaults to default_provider)
    -- default_translate_provider = "DeepL",

    -- Chat window layout: "float" (default) or "vsplit"
    chat_layout = "vsplit",
    vsplit_win = {
      width_percentage = 0.4, -- Width of the chat panel (0.2 - 0.7)
    },

    -- Global defaults for chat-type providers
    chat_provider_defaults = {
      stream = true,        -- Enable streaming for responsive chat
      temperature = 0.7,    -- Balanced creativity (0-2 scale)
      max_tokens = 4096,    -- Reasonable output limit for most models
    },

    -- Provider configurations
    providers = {
      OpenRouter = {
        provider = "OpenRouter",
        provider_type = "chat",  -- Required: "chat" or "translate"
        base_url = "https://openrouter.ai/api/v1",  -- Goes to /v1, endpoint appended automatically
        api_key_name = "OPENROUTER_API_KEY",
        default_model = "openai/gpt-5.5",
        fetch_models = true,  -- Enable dynamic model fetching
        -- Model overrides: can be array (just IDs) or table (with config)
        model_overrides = {
          "anthropic/claude-opus-4",
          "anthropic/claude-sonnet-4",
          ["openai/gpt-5.5"] = { temperature = 0.4 },
          ["google/gemini-2.5-flash"] = { max_tokens = 8192 },
        },
      },

      -- Example: Custom OpenAI-compatible provider
      aliyuncs = {
        provider = "aliyuncs",
        provider_type = "chat",
        base_url = "https://coding.dashscope.aliyuncs.com/v1",
        api_key_name = "ALIYUN_API_KEY",
        default_model = "qwen-turbo",
        max_tokens = 16384,  -- Override for this provider
        model_overrides = {
          "qwen-turbo",
          "qwen-plus",
        },
      },

      -- Example: NVIDIA NIM API
      nvidia = {
        provider = "nvidia",
        provider_type = "chat",
        base_url = "https://integrate.api.nvidia.com/v1",
        api_key_name = "NVIDIA_API_KEY",
        fetch_models = true,
      },

      -- Example: Translation provider (DeepL)
      DeepL = {
        provider = "DeepL",
        provider_type = "translate",  -- Required for non-chat APIs
        base_url = "http://localhost:1188/translate",  -- Complete endpoint URL
        api_key_name = "DEEPLX_API_KEY",
        default_model = "DeepLX",
        fetch_models = false,  -- Translate providers typically don't have /models endpoint
        model_overrides = {
          "DeepLX"
        },
      },
    },
  },
}
```

### Provider Configuration Fields

| Field                     | Required | Description                                                 |
| ------------------------- | -------- | ----------------------------------------------------------- |
| `provider`                | Yes      | Provider name (must match table key)                        |
| `provider_type`           | Yes      | `"chat"` or `"translate"`                                   |
| `base_url`                | Yes      | API base URL (chat: to `/v1`, translate: complete endpoint) |
| `api_key_name`            | Yes      | Environment variable name for API key                       |
| `default_model`           | Yes      | Default model ID                                            |
| `default_chat_model`      | No       | Default model for chat (falls back to default_model)        |
| `default_translate_model` | No       | Default model for translate (falls back to default_model)   |
| `fetch_models`            | No       | Enable dynamic model fetching (default: false)              |
| `cache_ttl`               | No       | Model cache TTL in hours (default: 24)                      |
| `model_overrides`         | No       | Model-specific settings (array or table)                    |

### Model Overrides

Two formats supported:

```lua
-- Array format (just model IDs, no special config)
model_overrides = {
  "model-a",
  "model-b",
}

-- Table format (model ID as key, with config)
model_overrides = {
  ["model-a"] = { temperature = 0.4 },
  ["model-b"] = { max_tokens = 8192 },
}
```

### Provider Types

- **`"chat"`**: OpenAI-compatible APIs. Request uses `/chat/completions` endpoint with OpenAI format.
- **`"translate"`**: Translation APIs (e.g., DeepL). Request uses custom format.

Note: Chat providers can be used for translation tasks, but translate providers cannot be used for chat.

## Default Configuration

```lua
-- Default providers
OpenRouter = {
  provider = "OpenRouter",
  provider_type = "chat",
  base_url = "https://openrouter.ai/api/v1",
  api_key_name = "OPENROUTER_API_KEY",
  default_model = "openai/gpt-5.5",
  default_translate_model = "google/gemini-2.0-flash-001",
  fetch_models = true,
}

-- Default options
default_provider = "OpenRouter",
chat_provider_defaults = {
  stream = true,
  temperature = 0.7,
  max_tokens = 4096,
},
chat_layout = "float",
user_prompt = "❯",
retry_key = "r",
```

## Usage

### Commands

| Command              | Description                                                        |
| -------------------- | ------------------------------------------------------------------ |
| `:LLM Chat`          | Start a new chat session                                           |
| `:LLM Toggle`        | Toggle chat window (open/close)                                    |
| `:LLM Sessions`      | Select and manage existing sessions                                |
| `:LLM ChatProviders` | Select provider@model (changes current chat if foreground, else sets default) |
| `:LLM TSProviders`   | Select translation provider                                        |
| `:LLM RefreshModels` | Refresh cached models from provider APIs                           |

### Model Selection Behavior

The `:LLM ChatProviders` command automatically adapts based on context:

| Context          | Behavior                                        |
| ---------------- | ----------------------------------------------- |
| Foreground chat  | Changes model for the current chat immediately  |
| No foreground chat | Sets default `chat_provider` for new chats    |

When changing a foreground chat's model:
- Session's provider/model are updated
- Window title and header refresh immediately
- Works even during conversation (not during active request)

### Chat Window Keymaps

| Key     | Action                                                         |
| ------- | -------------------------------------------------------------- |
| `<C-C>` | End current session                                            |
| `<C-S>` | Save current session                                           |
| `<C-N>` | Create new session                                             |
| `[q`    | Go to previous question (wrap)                                 |
| `]q`    | Go to next question (wrap)                                     |
| `r`     | Retry the question under cursor (when virtual text hint shows) |

### Session Picker Keymaps

| Key | Action         |
| --- | -------------- |
| `r` | Rename session |
| `d` | Delete session |

### Layered Picker Keymaps

| Key     | Action                                                          |
| ------- | --------------------------------------------------------------- |
| `Tab`   | Switch focus between Provider/Model panels                      |
| `Enter` | Confirm selection (switch to Model on Provider, close on Model) |
| `j/k`   | Navigate list                                                   |
| `r`     | Refresh models (bypass cache)                                   |
| `q`     | Close picker                                                    |

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

```lua
return {
  "MeanderingProgrammer/render-markdown.nvim",
  dependencies = {
    "nvim-treesitter/nvim-treesitter",
    "nvim-tree/nvim-web-devicons",
  },
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
    function() return "󰗊 ".. require("inobit.llm.api").is_translating() end,
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
