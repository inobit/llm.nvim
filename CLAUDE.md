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
- No call parentheses on single string/table args (`call_parentheses = "None"`)
- Never collapse simple statements (`collapse_simple_statement = "Never"`)

### Linting
No dedicated linter configured; rely on stylua for formatting consistency.

## Architecture

### Module Organization

```
lua/inobit/llm/
├── init.lua              -- Plugin entry point: sets up user commands (:LLM, :TS)
├── config.lua            -- Configuration management, provider installation and merging
├── api.lua               -- Public API surface (new_chat, open_session_selector, etc.)
├── chat.lua              -- Chat window lifecycle, streaming response handling, retry logic
├── session.lua           -- Session persistence (save/load to JSON), session index management
├── provider/             -- Provider classes (refactored from single provider.lua)
│   ├── init.lua          -- ProviderManager: registry, resolution, caching
│   ├── base.lua          -- Provider base class: HTTP client, abstract methods
│   ├── openai_protocol.lua -- OpenAIProtocol: SSE parsing, reasoning extraction
│   ├── openrouter.lua    -- OpenRouterProvider
│   ├── deepseek.lua      -- DeepSeekProvider
│   ├── standard_openai.lua -- StandardOpenAIProvider
│   ├── aliyun.lua        -- AliyunProvider (Qwen, custom endpoint)
│   ├── nvidia.lua        -- NvidiaProvider (NIM API)
│   └── deepl.lua         -- DeepLProvider (independent protocol)
├── models.lua            -- Model fetching and caching from provider APIs
├── dual_picker.lua       -- Layered picker window (Provider → Model selection)
├── translate.lua         -- Translation prompts and buffer replacement logic
├── win.lua               -- Window management (floating/vsplit), buffer creation, layout
├── highlights.lua        -- Extmark-based highlighting for user questions, retry hints
├── spinner.lua           -- Loading animation for chat and translation
├── block.lua             -- Block: passive UI layer for rendering content (Question/Response/Reasoning/Error/Warning)
├── turn.lua              -- Turn: state control center, drives Block lifecycle (begin/write/finish)
├── util.lua              -- UUID generation, string utilities
├── io.lua                -- File I/O utilities
├── notify.lua            -- User notifications
└── log.lua               -- Debug logging
```

### Key Design Patterns

**Turn/Block Architecture** (Streaming Response Rendering):
- **Turn** (`turn.lua`): State control center that perceives current phase and drives Block lifecycle
- **Block** (`block.lua`): Passive UI layer for rendering content, controlled by Turn
- Single-direction data flow: Event → Turn state → Block
- Block types: QuestionBlock, ResponseBlock, ReasoningBlock, ErrorBlock, WarningBlock
- Each Block has lifecycle: `begin()` (separator + start_row) → `write()` (content) → `finish()` (extmark + cleanup)
- Extmark ID encoding: Question uses `turn_id`, others use `turn_id * 10000 + offset`
- ReasoningBlock adds header/footer via virt_lines, updates header status (thinking → thought)

**Provider Architecture** (Refactored):
```
Provider (base)
├── OpenAIProtocol
│   ├── OpenRouterProvider
│   ├── DeepSeekProvider
│   └── StandardOpenAIProvider
└── DeepLProvider (independent protocol)
```

- **Provider base class** (`provider/base.lua`): HTTP utilities, abstract methods for protocol-specific implementations
- **OpenAIProtocol** (`provider/openai_protocol.lua`): SSE stream parsing, reasoning extraction, OpenAI API format
- **Specific providers**: Extend OpenAIProtocol or Provider base, configure `reasoning_field` for reasoning extraction

**Provider Configuration**: Uses `scenario_defaults` and per-provider configuration:
- `config.scenario_defaults` maps scenarios to default providers: `{ chat = "OpenRouter", translate = "DeepL" }`
- Each provider configures `supports_scenarios` ("all" or list), `scenario_models` for scenario-specific defaults
- `model_overrides` for per-model parameter overrides
- `params` for API parameters (temperature, max_tokens, etc.)

**Provider Resolution**: `ProviderManager:resolve_provider()` creates provider instances on-demand:
1. Takes `provider_name` and `model_id` as arguments
2. Builds a `cache_key` as `"Provider@Model"`
3. Returns cached instance if available (results are memoized)
4. Creates new instance by merging: `params` → `model_overrides[model_id]`
5. Selects appropriate class from `ProviderRegistry`

**Chat Session State**: Each chat session owns mutable state (not in Provider):
- `multi_round` - Enable multi-round conversation (default: true)
- `user_role` - Role name for user messages (default: "user")
- `show_reasoning` - Display reasoning/thinking content (default: true)
- Status window shows: `[Multi:ON] [Reason:ON] [Role:user] [Provider@model]`
- Toggle keymaps in chat buffers: `<A-M>` (multi-round), `<A-R>` (show_reasoning), `<A-L>` (cycle role)

**API Parameters**: Only API-relevant parameters in `params`:
- `stream` - Enable streaming response
- `temperature` - Sampling temperature (0-2)
- `max_tokens` - Maximum output tokens limit
- Provider-specific params (DeepL: `formality`, etc.)

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
3. User input captured, Turn created with `on_question()` event (renders QuestionBlock)
4. Provider makes HTTP request via `vim.system`, streaming response handled via SSE
5. Turn receives chunks: `on_reasoning_chunk()` → ReasoningBlock, `on_response_chunk()` → ResponseBlock
6. Turn lifecycle completes with `on_complete()`, `on_error()`, or `on_cancel()`
7. Session auto-saves via `session.lua` after each exchange

**Provider HTTP Layer**: Uses `vim.system` to execute curl commands for HTTP requests. Streaming responses handled via line-buffered stdout callbacks. `Provider:request()` returns job object with `kill()` and `is_active()` methods for lifecycle management.

**Retry Mechanism**: Implemented in `chat.lua` using extmarks and Block clearing. Virtual text hint shown via `highlights.lua`. When user presses retry key (`r` by default), blocks after the question are cleared via `Block.clear_blocks_after_row()`, and the message at cursor is resent with same context.

**Session Forking**: Sessions can be forked from any previous round via `SessionManager:fork_session(source, round)`. Forked sessions inherit the specified number of messages and display with a `└` indicator in the session picker. The `forked_from` and `inherited_count` fields track provenance.

**Chat Lifecycle & State Management**: `ChatManager` maintains a table of active chats keyed by session ID. Each `Chat` instance tracks:
- `requesting`: The active vim.system job (can be canceled for retry/override via `job:kill()`)
- `current_turn`: The active Turn instance managing Block lifecycle during streaming
- Window state via `win` field (response/input buffers and window IDs)

Turns manage phase transitions (question → reasoning → response → complete/error/cancel) and drive Block rendering. Blocks handle buffer writes and extmark-based highlighting automatically.

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
- `llm.Block` / `llm.BlockType` / `llm.BlockStatus` - Block rendering types
- `llm.Turn` / `llm.TurnPhase` / `llm.TurnStatus` - Turn state control types
- `llm.BlockInfo` - Block navigation info (start_row, end_row, extmark_id)

### Testing Structure
Tests use plenary.busted and mirror the module structure:
- `session_spec.lua` - Session persistence tests
- `session_integration_spec.lua` - Session fork/lifecycle integration tests
- `provider_spec.lua` - Provider configuration tests
- `layout_spec.lua` - Window layout tests
- `models_spec.lua` - Model fetching and caching tests
- `provider/base_spec.lua` - Provider base class tests
- `provider/openai_protocol_spec.lua` - OpenAI protocol parsing tests

Test setup uses `scripts/minimal_init.lua` which adds plenary.nvim to runtime path.

### User Commands

| Command | Implementation |
|---------|----------------|
| `:LLM Chat` | `api.new_chat()` |
| `:LLM Toggle` | `api.toggle_chat()` |
| `:LLM Sessions` | `api.open_session_selector()` |
| `:LLM Providers` | `api.open_provider_selector()` |
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