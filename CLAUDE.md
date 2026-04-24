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
├── config.lua    -- Configuration management, server flattening/merging
├── api.lua       -- Public API surface (new_chat, open_session_selector, etc.)
├── chat.lua      -- Chat window lifecycle, streaming response handling, retry logic
├── session.lua   -- Session persistence (save/load to JSON), session index management
├── server.lua    -- HTTP client for LLM APIs (OpenAI/OpenRouter/DeepL), request building
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

**Server Configuration Hierarchy**: The `config.lua` module flattens server configs from `server@model` format. Default servers are merged with user-provided configs via `install_servers()`. Each server entry contains `base_url`, `api_key_name`, `stream`, `multi_round`, and model-specific options.

**Chat Session Flow**:
1. `api.new_chat()` → `ChatManager:new()` creates or reuses a session
2. `win.lua` creates floating or vsplit windows based on `config.options.chat_layout`
3. User input is captured, `server.lua` makes HTTP request via plenary.curl
4. Streaming response is written to response buffer with `spinner.lua` feedback
5. Session auto-saves via `session.lua` after each exchange

**Server Class Hierarchy**: Server implementations use inheritance via Lua metatables:
- `Server` (base) → `ChatServer` → `OpenAIServer` → `OpenRouterServer`
- `Server` (base) → `TranslateServer`
Each level adds protocol-specific behavior (e.g., `OpenRouterServer` adds `HTTP-Referer` and `X-Title` headers).

**Retry Mechanism**: Implemented in `chat.lua` using extmarks. Virtual text hint shown via `highlights.lua`. When user presses retry key (`r` by default), the message at cursor is resent with same context.

**Session Forking**: Sessions can be forked from any previous round via `SessionManager:fork_session(source, round)`. Forked sessions inherit the specified number of messages and display with a `└` indicator in the session picker. The `forked_from` and `inherited_count` fields track provenance.

**Reasoning Content Extraction**: For models that output reasoning (e.g., Claude thinking tags), `chat.lua` parses `<think>` tags during streaming, storing reasoning separately from the main response. The `reasoning_content` field in messages preserves this data for multi-round conversations.

**Chat Lifecycle & State Management**: `ChatManager` maintains a table of active chats keyed by session ID. Each `Chat` instance tracks:
- `requesting`: The active plenary.curl job (can be canceled for retry/override)
- `start_think`/`start_answer`: Parser state for streaming responses
- `current_response`: Accumulated response buffer during streaming
- Window state via `win` field (response/input buffers and window IDs)

Chats can be in foreground (windows visible), background (hidden but session persists), or closed state. The vsplit layout closes old windows before opening new ones to avoid layout conflicts.

**Translation Pipeline**: `translate.lua` builds structured prompts for different translation types (E2Z, Z2E, Z2E_CAMEL, Z2E_UNDERLINE). Uses dedicated translation server or falls back to chat server. Results replace buffer text or show in floating window.

### Type Annotations
Extensive use of LuaCATS annotations:
- `llm.Config` - Main configuration type
- `llm.Session` / `llm.SessionIndex` - Session data structures
- `llm.server.ServerOptions` - Server configuration
- `llm.Chat` - Active chat instance

### Testing Structure
Tests use plenary.busted and mirror the module structure:
- `session_spec.lua` - Session persistence tests
- `session_integration_spec.lua` - Session fork/lifecycle integration tests
- `server_spec.lua` - Server configuration tests
- `layout_spec.lua` - Window layout tests

Test setup uses `scripts/minimal_init.lua` which adds plenary.nvim to runtime path.

### User Commands

| Command | Implementation |
|---------|----------------|
| `:LLM Chat` | `api.new_chat()` |
| `:LLM Sessions` | `api.open_session_selector()` |
| `:LLM ChatServers` | `api.open_chat_server_selector()` |
| `:LLM TSServers` | `api.open_translate_server_selector()` |
| `:TS <type> <text>` | `api.translate_in_cmdline()` |

### Dependencies

- **Required**: [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) (curl, Path, async)
- **Optional**: [render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim) for markdown rendering in chat windows (set `vim.g.inobit_filetype = "inobit"`)
- **Dev dependency**: plenary.nvim for tests

### Session Storage
Sessions stored as JSON in `stdpath("cache")/inobit/llm/session/`:
- Session index (`session_list.json`) maps IDs to metadata
- Individual session files (`{uuid}.json`) contain message history
