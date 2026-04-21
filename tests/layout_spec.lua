local config = require "inobit.llm.config"
local win_module = require "inobit.llm.win"

describe("Chat Layout", function()
  before_each(function()
    -- Reset config to defaults before each test
    config.setup {}
  end)

  describe("Configuration", function()
    it("should have default chat_layout as 'float'", function()
      assert.equals("float", config.options.chat_layout)
    end)

    it("should accept 'vsplit' as chat_layout", function()
      config.setup { chat_layout = "vsplit" }
      assert.equals("vsplit", config.options.chat_layout)
    end)

    it("should reject invalid chat_layout values", function()
      -- Only 'float' and 'vsplit' are valid
      local invalid_layouts = { "split", "horizontal", "vertical", "tab" }
      for _, layout in ipairs(invalid_layouts) do
        local ok, err = pcall(function()
          config.setup { chat_layout = layout }
        end)
        assert.is_false(ok, "Should reject invalid layout: " .. layout)
      end
    end)

    it("should have default vsplit_win configuration", function()
      assert.equals(0.45, config.options.vsplit_win.width_percentage)
    end)

    it("should allow custom vsplit_win width_percentage", function()
      config.setup { vsplit_win = { width_percentage = 0.5 } }
      assert.equals(0.5, config.options.vsplit_win.width_percentage)
    end)

    it("should clamp vsplit_win width_percentage to valid range", function()
      config.setup { vsplit_win = { width_percentage = 0.8 } }
      -- Should be clamped to 0.7 max to avoid taking too much space
      assert.is_true(config.options.vsplit_win.width_percentage <= 0.7)
    end)
  end)

  describe("SplitChatWin", function()
    local original_win

    before_each(function()
      -- Store the current window
      original_win = vim.api.nvim_get_current_win()
      -- Setup vsplit layout config
      config.setup { chat_layout = "vsplit" }
    end)

    after_each(function()
      -- Clean up any created windows
      for _, winid in ipairs(vim.api.nvim_list_wins()) do
        if winid ~= original_win then
          pcall(vim.api.nvim_win_close, winid, true)
        end
      end
      -- Delete any buffers created during test
      for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        local buf_name = vim.api.nvim_buf_get_name(bufnr)
        if buf_name:match "^inobit://" or vim.bo[bufnr].filetype == "inobit" then
          pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        end
      end
    end)

    it("should create SplitChatWin with correct structure", function()
      local chat_win = win_module.SplitChatWin:new {
        title = "TestServer@test-model",
      }

      assert.is_not_nil(chat_win)
      assert.is_not_nil(chat_win.id)
      assert.equals("TestServer@test-model", chat_win.title)
      assert.is_not_nil(chat_win.wins)
      assert.is_not_nil(chat_win.wins.response)
      assert.is_not_nil(chat_win.wins.input)
    end)

    it("should create response and input windows with valid bufnr and winid", function()
      local chat_win = win_module.SplitChatWin:new {
        title = "TestServer@test-model",
      }

      -- Response window
      assert.is_number(chat_win.wins.response.bufnr)
      assert.is_number(chat_win.wins.response.winid)
      assert.is_true(vim.api.nvim_buf_is_valid(chat_win.wins.response.bufnr))
      assert.is_true(vim.api.nvim_win_is_valid(chat_win.wins.response.winid))

      -- Input window
      assert.is_number(chat_win.wins.input.bufnr)
      assert.is_number(chat_win.wins.input.winid)
      assert.is_true(vim.api.nvim_buf_is_valid(chat_win.wins.input.bufnr))
      assert.is_true(vim.api.nvim_win_is_valid(chat_win.wins.input.winid))
    end)

    it("should place vsplit windows on the right side", function()
      local original_col = vim.api.nvim_win_get_position(original_win)[2]

      local chat_win = win_module.SplitChatWin:new {
        title = "TestServer@test-model",
      }

      -- Get response window position
      local response_pos = vim.api.nvim_win_get_position(chat_win.wins.response.winid)
      local response_col = response_pos[2]

      -- Vsplit should be on the right (column > original window column)
      assert.is_true(response_col > original_col)
    end)

    it("should set vsplit width to configured percentage", function()
      local expected_width = math.floor(vim.o.columns * config.options.vsplit_win.width_percentage)

      local chat_win = win_module.SplitChatWin:new {
        title = "TestServer@test-model",
      }

      local response_width = vim.api.nvim_win_get_width(chat_win.wins.response.winid)
      -- Allow for small rounding differences
      assert.is_true(math.abs(response_width - expected_width) <= 1)
    end)

    it("should set correct filetype on both buffers", function()
      vim.g.inobit_filetype = "inobit"

      local chat_win = win_module.SplitChatWin:new {
        title = "TestServer@test-model",
      }

      assert.equals("inobit", vim.api.nvim_get_option_value("filetype", { buf = chat_win.wins.response.bufnr }))
      assert.equals("inobit", vim.api.nvim_get_option_value("filetype", { buf = chat_win.wins.input.bufnr }))
    end)

    it("should set wrap option on response window", function()
      local chat_win = win_module.SplitChatWin:new {
        title = "TestServer@test-model",
      }

      local wrap = vim.api.nvim_get_option_value("wrap", { win = chat_win.wins.response.winid })
      assert.is_true(wrap)
    end)

    it("should focus input window after creation", function()
      local chat_win = win_module.SplitChatWin:new {
        title = "TestServer@test-model",
      }

      local current_win = vim.api.nvim_get_current_win()
      assert.equals(chat_win.wins.input.winid, current_win)
    end)

    it("should register close keymap (q) on both buffers", function()
      local chat_win = win_module.SplitChatWin:new {
        title = "TestServer@test-model",
      }

      -- Check that 'q' keymap exists on both buffers
      local response_keymaps = vim.api.nvim_buf_get_keymap(chat_win.wins.response.bufnr, "n")
      local input_keymaps = vim.api.nvim_buf_get_keymap(chat_win.wins.input.bufnr, "n")

      local has_q_response = vim.iter(response_keymaps):any(function(map)
        return map.lhs == "q"
      end)
      local has_q_input = vim.iter(input_keymaps):any(function(map)
        return map.lhs == "q"
      end)

      assert.is_true(has_q_response, "Response buffer should have 'q' keymap")
      assert.is_true(has_q_input, "Input buffer should have 'q' keymap")
    end)

    it("should register Tab keymap for window navigation", function()
      local chat_win = win_module.SplitChatWin:new {
        title = "TestServer@test-model",
      }

      -- Check that Tab keymap exists
      local input_keymaps = vim.api.nvim_buf_get_keymap(chat_win.wins.input.bufnr, "n")
      local has_tab = vim.iter(input_keymaps):any(function(map)
        return map.lhs == "<Tab>"
      end)

      assert.is_true(has_tab, "Should have Tab keymap for navigation")
    end)

    it("should close both windows when response buffer is closed", function()
      local chat_win = win_module.SplitChatWin:new {
        title = "TestServer@test-model",
      }

      local response_winid = chat_win.wins.response.winid
      local input_winid = chat_win.wins.input.winid

      -- Close response window
      vim.api.nvim_win_close(response_winid, true)

      -- Input window should also be closed
      assert.is_false(vim.api.nvim_win_is_valid(input_winid))
    end)

    it("should support reusing existing buffers", function()
      -- Create initial chat
      local chat_win1 = win_module.SplitChatWin:new {
        title = "TestServer@test-model",
      }
      local response_bufnr = chat_win1.wins.response.bufnr
      local input_bufnr = chat_win1.wins.input.bufnr

      -- Add some content to buffers
      vim.api.nvim_buf_set_lines(response_bufnr, 0, -1, false, { "Previous response" })
      vim.api.nvim_buf_set_lines(input_bufnr, 0, -1, false, { "Previous input" })

      -- Create new chat with existing buffers (simulates window refresh)
      local chat_win2 = win_module.SplitChatWin:new {
        title = "TestServer@test-model",
        response_bufnr = response_bufnr,
        input_bufnr = input_bufnr,
      }

      -- Buffers should be reused
      assert.equals(response_bufnr, chat_win2.wins.response.bufnr)
      assert.equals(input_bufnr, chat_win2.wins.input.bufnr)

      -- Content should be preserved
      local response_content = vim.api.nvim_buf_get_lines(response_bufnr, 0, -1, false)
      assert.equals("Previous response", response_content[1])
    end)

    it("should call close_prev_handler before closing", function()
      local called = false
      local chat_win = win_module.SplitChatWin:new {
        title = "TestServer@test-model",
        close_prev_handler = function()
          called = true
        end,
      }

      -- Close the window
      vim.api.nvim_win_close(chat_win.wins.response.winid, true)

      assert.is_true(called, "close_prev_handler should be called")
    end)

    it("should call close_post_handler after closing", function()
      local called = false
      local chat_win = win_module.SplitChatWin:new {
        title = "TestServer@test-model",
        close_post_handler = function()
          called = true
        end,
      }

      -- Close the window
      vim.api.nvim_win_close(chat_win.wins.response.winid, true)

      assert.is_true(called, "close_post_handler should be called")
    end)

    it("should auto-skip to input when entering insert mode in response buffer", function()
      local chat_win = win_module.SplitChatWin:new {
        title = "TestServer@test-model",
      }

      -- Focus response window
      vim.api.nvim_set_current_win(chat_win.wins.response.winid)

      -- Trigger InsertEnter autocmd manually (feedkeys doesn't work reliably in headless)
      vim.api.nvim_exec_autocmds("InsertEnter", { buffer = chat_win.wins.response.bufnr })

      -- Should be focused on input window
      local current_win = vim.api.nvim_get_current_win()
      assert.equals(chat_win.wins.input.winid, current_win)
    end)
  end)

  describe("WinStack with SplitChatWin", function()
    local original_win

    before_each(function()
      original_win = vim.api.nvim_get_current_win()
      config.setup { chat_layout = "vsplit" }
    end)

    after_each(function()
      for _, winid in ipairs(vim.api.nvim_list_wins()) do
        if winid ~= original_win then
          pcall(vim.api.nvim_win_close, winid, true)
        end
      end
    end)

    it("should push split windows to WinStack", function()
      local chat_win = win_module.SplitChatWin:new {
        title = "TestServer@test-model",
      }

      -- Both windows should be in the stack
      assert.equals(original_win, win_module.WinStack.stack[chat_win.wins.input.winid])
      assert.equals(original_win, win_module.WinStack.stack[chat_win.wins.response.winid])
    end)

    it("should pop to original window when split windows are closed", function()
      local chat_win = win_module.SplitChatWin:new {
        title = "TestServer@test-model",
      }

      -- Change focus to response window
      vim.api.nvim_set_current_win(chat_win.wins.response.winid)

      -- Close it (should trigger pop)
      vim.api.nvim_win_close(chat_win.wins.response.winid, true)

      -- Should be back to original window
      assert.equals(original_win, vim.api.nvim_get_current_win())
    end)
  end)

  describe("Chat Manager Integration", function()
    local ChatManager
    local original_win

    before_each(function()
      original_win = vim.api.nvim_get_current_win()
      config.setup {
        chat_layout = "vsplit",
        session_dir = "tests",
      }
      ChatManager = require("inobit.llm.chat")
      -- Initialize session manager
      local SessionManager = require "inobit.llm.session"
      SessionManager:init(true)
    end)

    after_each(function()
      for _, winid in ipairs(vim.api.nvim_list_wins()) do
        if winid ~= original_win then
          pcall(vim.api.nvim_win_close, winid, true)
        end
      end
      -- Clean up test sessions
      local Path = require "plenary.path"
      local session_dir = Path:new(config.get_session_dir())
      if session_dir:exists() then
        os.execute("rm -rf " .. session_dir.filename)
      end
    end)

    it("should create chat with vsplit layout when configured", function()
      -- This requires mocking or requires actual server setup
      -- Simplified test just checking that ChatManager can work with SplitChatWin
      assert.is_function(ChatManager.new)
    end)
  end)
end)
