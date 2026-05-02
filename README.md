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
    { "<leader>ap", "<Cmd>LLM Providers<CR>", desc = "LLM: select provider" },
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
    -- Default providers for each scenario
    scenario_defaults = {
      chat = "OpenRouter",
      translate = "DeepL",
    },

    -- Chat window layout: "float" (default) or "vsplit"
    chat_layout = "vsplit",
    split_chat = {
      width_percentage = 0.4, -- Width of the chat panel (0.2 - 0.7)
    },

    -- Status toggle keymaps (in chat window)
    status_keymaps = {
      toggle_multi_round = "<A-m>",    -- Toggle multi-round conversation mode
      toggle_show_reasoning = "<A-r>", -- Toggle reasoning/thinking content display
      cycle_user_role = "<A-l>",       -- Cycle user role (user → assistant → system)
    },

    -- Provider configurations
    providers = {
      OpenRouter = {
        base_url = "https://openrouter.ai/api/v1",
        api_key_name = "OPENROUTER_API_KEY",
        supports_scenarios = "all",
        scenario_models = {
          chat = "openai/gpt-5.5",
          translate = "google/gemini-2.0-flash-001",
        },
        default_model = "openai/gpt-5.5",
        fetch_models = true,
        params = {
          temperature = 0.6,
          max_tokens = 4096,
        },
        model_overrides = {
          "anthropic/claude-opus-4",
          "anthropic/claude-sonnet-4",
          ["openai/gpt-5.5"] = { temperature = 0.4 },
          ["google/gemini-2.5-flash"] = { max_tokens = 8192 },
        },
      },

      -- Example: Custom OpenAI-compatible provider
      Aliyun = {
        base_url = "https://dashscope.aliyuncs.com/compatible-mode/v1",
        api_key_name = "ALIYUN_API_KEY",
        supports_scenarios = "all",
        default_model = "kimi-k2.5",
        params = {
          temperature = 0.6,
          max_tokens = 16384,
        },
        model_overrides = {
          "qwen-turbo",
          "qwen-plus",
        },
      },

      -- Example: NVIDIA NIM API
      Nvidia = {
        base_url = "https://integrate.api.nvidia.com/v1",
        api_key_name = "NVIDIA_API_KEY",
        supports_scenarios = "all",
        default_model = "deepseek-ai/deepseek-v4-pro",
        fetch_models = true,
        params = {
          temperature = 0.6,
          max_tokens = 16384,
        },
      },

      -- Example: Translation provider (DeepL)
      DeepL = {
        base_url = "https://api-free.deepl.com/v2",
        api_key_name = "DEEPL_API_KEY",
        supports_scenarios = { "translate" },
        default_model = "deepl",
        fetch_models = false,
        params = {
          formality = "default",
        },
      },
    },
  },
}
```

### Provider Configuration Fields

| Field               | Required | Description                                                  |
| ------------------- | -------- | ------------------------------------------------------------ |
| `base_url`          | Yes      | API base URL (to `/v1` level, endpoint appended automatically) |
| `api_key_name`      | No       | Environment variable name for API key (can be `false` to disable) |
| `supports_scenarios`| No       | `"all"` or list like `{ "chat", "translate" }` (default: `"all"`) |
| `scenario_models`   | No       | Scenario-specific models: `{ chat = "model-a", translate = "model-b" }` |
| `default_model`     | Yes      | Default model ID                                             |
| `fetch_models`      | No       | Enable dynamic model fetching (default: false)               |
| `cache_ttl`         | No       | Model cache TTL in hours (default: 24)                       |
| `params`            | No       | API parameters (temperature, max_tokens, stream, etc.)       |
| `model_overrides`   | No       | Model-specific settings (array or table)                     |

### Highlight Configuration

Customize the appearance of different content types in chat windows:

```lua
opts = {
  -- Question (user input) highlight
  question_hi = "Question",  -- highlight group name

  -- Reasoning/thinking content highlight and styling
  reasoning_hi = "Comment",     -- highlight group for reasoning content
  reasoning_icon = "💭",        -- icon for reasoning block header

  -- Response highlight
  response_hi = "Normal",       -- highlight group for AI response

  -- Error/Warning highlights
  error_hi = "ErrorMsg",        -- error message highlight
  warning_hi = "WarningMsg",    -- warning/cancel message highlight
}
```

You can use any highlight group name, or create custom highlights:

```lua
opts = {
  reasoning_hi = { fg = "#6a9fb5", italic = true },
}
```

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

### Provider Scenarios

- **`supports_scenarios = "all"`**: Provider supports both chat and translation scenarios.
- **`supports_scenarios = { "chat" }`**: Provider only supports chat (e.g., specialized chat APIs).
- **`supports_scenarios = { "translate" }`**: Provider only supports translation (e.g., DeepL).

Use `scenario_models` to specify different default models for each scenario:
```lua
scenario_models = {
  chat = "openai/gpt-5.5",
  translate = "google/gemini-2.0-flash-001",
}
```

## Default Configuration

```lua
-- Default providers for each scenario
scenario_defaults = {
  chat = "OpenRouter",
  translate = "OpenRouter",
}

-- Default provider configurations
OpenRouter = {
  base_url = "https://openrouter.ai/api/v1",
  api_key_name = "OPENROUTER_API_KEY",
  supports_scenarios = "all",
  scenario_models = {
    chat = "openai/gpt-5.5",
    translate = "google/gemini-2.0-flash-001",
  },
  default_model = "openai/gpt-5.5",
  fetch_models = true,
  params = {
    temperature = 0.6,
    max_tokens = 4096,
  },
}

-- Default options
chat_layout = "float",
user_prompt = "❯",
retry_key = "r",

-- Highlight configuration
question_hi = "Question",
reasoning_hi = "Comment",
reasoning_icon = "💭",
response_hi = "Normal",
error_hi = "ErrorMsg",
warning_hi = "WarningMsg",

-- Status toggle keymaps
status_keymaps = {
  toggle_multi_round = "<A-m>",
  toggle_show_reasoning = "<A-r>",
  cycle_user_role = "<A-l>",
},
```

## Usage

### Commands

| Command              | Description                                                        |
| -------------------- | ------------------------------------------------------------------ |
| `:LLM Chat`          | Start a new chat session                                           |
| `:LLM Toggle`        | Toggle chat window (open/close)                                    |
| `:LLM Sessions`      | Select and manage existing sessions                                |
| `:LLM Providers`     | Select provider@model for a scenario (changes current chat if foreground) |
| `:LLM RefreshModels` | Refresh cached models from provider APIs                           |

### Model Selection Behavior

The `:LLM Providers` command workflow:
1. First, select a **scenario** (chat or translate)
2. Then select **provider** and **model** in the layered picker

For **chat scenario**, if there's a foreground chat, the model change applies immediately to that chat. Otherwise, it sets the default for new chats.

For **translate scenario**, the selection sets the default provider for translation tasks.

When changing a foreground chat's model:
- Session's provider/model are updated
- Window header refreshes immediately
- Works even during conversation (not during active request)

### Chat Window Keymaps

| Key     | Action                                                          |
| ------- | --------------------------------------------------------------- |
| `<C-C>` | End current session                                             |
| `<C-S>` | Save current session                                            |
| `<C-N>` | Create new session                                              |
| `[q`    | Go to previous question (wrap)                                  |
| `]q`    | Go to next question (wrap)                                      |
| `r`     | Retry the question under cursor (when virtual text hint shows)  |
| `<A-m>` | Toggle multi-round conversation mode                            |
| `<A-r>` | Toggle reasoning/thinking content display                       |
| `<A-l>` | Cycle user role (user → assistant → system → user)              |

**Note**: The `<A-m>`, `<A-r>`, and `<A-l>` keymaps can be customized via the `status_keymaps` configuration option.

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
