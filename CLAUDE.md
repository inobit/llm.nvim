# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is **llm.nvim**, a Neovim plugin for AI chat functionality supporting OpenRouter and any OpenAI-compatible API. It provides floating/vsplit chat windows, session management, streaming responses, and in-buffer translation.

## Development Commands

### Running Tests
Tests use the plenary.nvim test framework:

```bash
# Run all tests
nvim --headless -u scripts/minimal_init.lua -c "PlenaryBustedDirectory tests/ { minimal_init = './scripts/minimal_init.lua' }" -c "qa"

# Run a specific test file
nvim --headless -u scripts/minimal_init.lua -c "PlenaryBustedFile tests/session_spec.lua" -c "qa"
```

### Code Formatting
Uses stylua for Lua formatting:

location:
`~/.local/share/nvim/mason/bin/stylua`

```bash
# Format all Lua files
stylua .

# Check formatting without changes
stylua --check .
```

Configuration is in `.stylua.toml`:
- 120 column width
- 2-space indentation
- Auto-prefer double quotes
- Unix line endings

### Linting
No dedicated linter configured; rely on stylua for formatting consistency.

## Architecture

### Module Organization

```
lua/inobit/llm/
├── init.lua      -- Plugin entry point: sets up user commands (:LLM, :TS)
├── config.lua    -- Configuration management, provider installation and merging
├── api.lua       -- Public API surface (new_chat, open_session_selector, etc.)
├── chat.lua      -- Chat window lifecycle, streaming response handling, retry logic
├── session.lua   -- Session persistence (save/load to JSON), session index management
├── provider.lua  -- ProviderManager: HTTP client, provider resolution, request building
├── models.lua    -- Model fetching and caching from provider APIs
├── dual_picker.lua -- Layered picker window (Provider → Model selection)
├── translate.lua -- Translation prompts and buffer replacement logic
├── win.lua       -- Window management (floating/vsplit), buffer creation, layout
├── highlights.lua -- Extmark-based highlighting for user questions, retry hints
├── spinner.lua   -- Loading animation for chat and translation
├── util.lua      -- UUID generation, string utilities
├── io.lua        -- File I/O utilities
├── notify.lua    -- User notifications
└── log.lua       -- Debug logging
```

### Key Design Patterns

**Provider Configuration Hierarchy**: Configuration uses a Provider → Model hierarchy:
- `config.providers` is a table keyed by provider name (e.g., `OpenRouter`)
- Each `ProviderEntry` contains base settings (`base_url`, `api_key_name`, `provider_type`)
- `model_overrides` table provides model-specific settings keyed by model ID (can be array of strings or table with configs)
- `default_model` specifies the fallback model when no overrides match
- Provider configs are merged via `install_providers()` - defaults are extended with user configs

**Provider Types**: `provider_type` is a **required field**:
- `"chat"` - Chat providers (OpenAI-compatible APIs), use OpenAI request format
- `"translate"` - Translation providers (e.g., DeepL), use custom request format

**Base URL Design**:
- **Chat providers**: `base_url` goes to `/v1` level (e.g., `https://openrouter.ai/api/v1`). Endpoint `/chat/completions` is appended automatically.
- **Translate providers**: `base_url` is the complete endpoint URL (e.g., `https://api-free.deepl.com/v2/translate`)

**Provider Resolution Pattern**: `ProviderManager:resolve_provider()` creates provider instances on-demand:
1. Takes `provider_name` and `model_id` as arguments
2. Builds a `cache_key` as `"Provider@Model"`
3. Returns cached instance if available (results are memoized)
4. Creates new instance by merging: `chat_provider_defaults` → `provider_entry` → `model_overrides`
5. Selects appropriate class based on `provider_type` (`OpenRouterProvider`, `OpenAIProvider`, `DeepLProvider`, etc.)

**API Parameters**: Only 3 common parameters are passed to API request body:
- `stream` - Enable streaming response
- `temperature` - Sampling temperature (0-2)
- `max_tokens` - Maximum output tokens limit

Internal parameters (`multi_round`, `user_role`) are not sent to API.

**Dynamic Model Fetching**: `models.lua` fetches available models from provider APIs:
- Each provider can enable `fetch_models: true` to query the `/models` endpoint
- Results are cached in `stdpath("cache")/inobit/llm/models/{provider}.json`
- `cache_ttl` (hours) controls cache expiration (default: 24 hours)
- Built-in fetchers for OpenRouter, OpenAI, DeepSeek; default OpenAI-compatible for others
- Cache invalidation via `:LLM RefreshModels` command

**Layered Provider Selection**: `dual_picker.lua` provides a two-panel picker UI:
- Left panel: Provider list (chat providers for chat type, all providers for translate type)
- Right panel: Model list (model_overrides first, then fetched models)
- Tab switches focus between panels, Enter confirms selection
- `r` key refreshes models (bypasses cache)
- Window layout: Provider 20%, Model 80% of total picker width

**Chat Session Flow**:
1. `api.new_chat()` → `ChatManager:new()` creates or reuses a session
2. `win.lua` creates floating or vsplit windows based on `config.options.chat_layout`
3. User input is captured, `provider.lua` makes HTTP request via `vim.system`
4. Streaming response is written to response buffer with `spinner.lua` feedback
5. Session auto-saves via `session.lua` after each exchange

**Provider Class Hierarchy**: Provider implementations use inheritance via Lua metatables:
- `Provider` (base) → `ChatProvider` → `OpenAIProvider` → `OpenRouterProvider`
- `Provider` (base) → `TranslateProvider` → `DeepLProvider`
Each level adds protocol-specific behavior (e.g., `OpenRouterProvider` adds `HTTP-Referer` and `X-Title` headers).

**Provider HTTP Layer**: Uses `vim.system` to execute curl commands for HTTP requests. Streaming responses are handled via line-buffered stdout callbacks. The `Provider:request()` method returns a job object with `kill()` and `is_active()` methods for lifecycle management.

**Retry Mechanism**: Implemented in `chat.lua` using extmarks. Virtual text hint shown via `highlights.lua`. When user presses retry key (`r` by default), the message at cursor is resent with same context.

**Session Forking**: Sessions can be forked from any previous round via `SessionManager:fork_session(source, round)`. Forked sessions inherit the specified number of messages and display with a `└` indicator in the session picker. The `forked_from` and `inherited_count` fields track provenance.

**Chat Lifecycle & State Management**: `ChatManager` maintains a table of active chats keyed by session ID. Each `Chat` instance tracks:
- `requesting`: The active vim.system job (can be canceled for retry/override via `job:kill()`)
- `start_think`/`start_answer`: Parser state for streaming responses
- `current_response`: Accumulated response buffer during streaming
- Window state via `win` field (response/input buffers and window IDs)

Chats can be in foreground (windows visible), background (hidden but session persists), or closed state. The vsplit layout closes old windows before opening new ones to avoid layout conflicts.

**Translation Pipeline**: `translate.lua` builds structured prompts for different translation types (E2Z, Z2E, Z2E_CAMEL, Z2E_UNDERLINE). Uses dedicated translation provider or falls back to chat provider. Results replace buffer text or show in floating window.

### Type Annotations
Extensive use of LuaCATS annotations:
- `llm.Config` - Main configuration type
- `llm.Session` / `llm.SessionIndex` - Session data structures
- `llm.config.ProviderEntry` - Provider configuration entry (hierarchical model)
- `llm.config.ModelOverride` - Model-specific settings override
- `llm.provider.ProviderOptions` - Resolved provider instance options
- `llm.Provider` - Provider instance (base class)
- `llm.ProviderManager` - Provider manager singleton
- `llm.DualPickerWin` - Layered picker window
- `llm.Chat` - Active chat instance

### Testing Structure
Tests use plenary.busted and mirror the module structure:
- `session_spec.lua` - Session persistence tests
- `session_integration_spec.lua` - Session fork/lifecycle integration tests
- `provider_spec.lua` - Provider configuration tests
- `layout_spec.lua` - Window layout tests
- `models_spec.lua` - Model fetching and caching tests

Test setup uses `scripts/minimal_init.lua` which adds plenary.nvim to runtime path.

### User Commands

| Command | Implementation |
|---------|----------------|
| `:LLM Chat` | `api.new_chat()` |
| `:LLM Sessions` | `api.open_session_selector()` |
| `:LLM ChatProviders` | `api.open_chat_provider_selector()` (layered picker) |
| `:LLM TSProviders` | `api.open_translate_provider_selector()` |
| `:LLM RefreshModels` | `api.refresh_models_cache()` |
| `:TS <type> <text>` | `api.translate_in_cmdline()` |

### Dependencies

- **Required**: curl binary (for HTTP requests via vim.system)
- **Required**: [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) (Path, async utilities)
- **Optional**: [render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim) for markdown rendering in chat windows (set `vim.g.inobit_filetype = "inobit"`)
- **Dev dependency**: plenary.nvim for tests

### Session Storage
Sessions stored as JSON in `stdpath("cache")/inobit/llm/session/`:
- Session index (`session_list.json`) maps IDs to metadata
- Individual session files (`{uuid}.json`) contain message history