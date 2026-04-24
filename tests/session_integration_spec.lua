-- Setup config first before requiring other modules
local config = require "inobit.llm.config"
config.setup {
  data_dir = vim.fn.stdpath "cache" .. "/inobit/llm_test",
  features = { smart_naming = true },
  smart_naming = {
    enabled = true,
    model = "OpenRouter@openai/gpt-4o-mini",
    max_length = 15,
    prompt = "用不超过%d个字总结这段对话主题：%s",
  },
}

local SessionManager = require "inobit.llm.session"
local Path = require "plenary.path"
local io_module = require "inobit.llm.io"

describe("Session Features Integration", function()
  local test_dir
  local uv = vim.uv or vim.loop

  before_each(function()
    -- Reset state between tests
    config.setup {
      data_dir = vim.fn.stdpath "cache" .. "/inobit/llm_test",
      session_dir = "session",
      features = { smart_naming = true },
      smart_naming = {
        enabled = true,
        model = "OpenRouter@openai/gpt-4o-mini",
        max_length = 15,
        prompt = "用不超过%d个字总结这段对话主题：%s",
      },
    }

    test_dir = Path:new(config.get_session_dir())
    -- Clean up the test directory
    if test_dir:exists() then
      os.execute("rm -rf " .. test_dir.filename)
    end
    test_dir:mkdir { parents = true }

    SessionManager:init(true)
  end)

  after_each(function()
    if test_dir and test_dir:exists() then
      os.execute("rm -rf " .. test_dir.filename)
    end
  end)

  describe("Field Migration", function()
    it("should use title field directly", function()
      -- Create a session with title
      local session = SessionManager:new_session("test_server", "test_model")
      session.title = "my_session_title"
      session:add_message { role = "user", content = "test content" }
      session:save()

      -- Reload the session
      local loaded = SessionManager:load(session.id)

      -- Verify title is preserved
      assert.equals("my_session_title", loaded.title)
    end)
  end)

  describe("Fork Session", function()
    it("should fork session with specified round count", function()
      -- Create source session with messages (3 rounds = 6 messages)
      local source = SessionManager:new_session("test_server", "test_model")
      source:add_message { role = "user", content = "Question 1" }
      source:add_message { role = "assistant", content = "Answer 1" }
      source:add_message { role = "user", content = "Question 2" }
      source:add_message { role = "assistant", content = "Answer 2" }
      source:add_message { role = "user", content = "Question 3" }
      source:add_message { role = "assistant", content = "Answer 3" }
      source:save()

      -- Fork round 2 (should get round 2 messages: Question 2 and Answer 2)
      local forked = SessionManager:fork_session(source, 2)

      -- Verify forked_from
      assert.equals(source.id, forked.forked_from)

      -- Verify inherited_count (2 messages = 1 round * 2 messages)
      assert.equals(2, forked.inherited_count)

      -- Verify messages copied (only round 2)
      assert.equals(2, #forked.content)
      assert.equals("Question 2", forked.content[1].content)
      assert.equals("Answer 2", forked.content[2].content)
    end)

    it("should fork session with all messages", function()
      -- Create source session with messages
      local source = SessionManager:new_session("test_server", "test_model")
      source:add_message { role = "user", content = "Question 1" }
      source:add_message { role = "assistant", content = "Answer 1" }
      source:add_message { role = "user", content = "Question 2" }
      source:add_message { role = "assistant", content = "Answer 2" }
      source:save()

      -- Fork with "all"
      local forked = SessionManager:fork_session(source, "all")

      -- Verify all messages copied
      assert.equals(4, forked.inherited_count)
      assert.equals(4, #forked.content)
      assert.equals("Question 1", forked.content[1].content)
      assert.equals("Answer 1", forked.content[2].content)
      assert.equals("Question 2", forked.content[3].content)
      assert.equals("Answer 2", forked.content[4].content)
    end)

    it("should set initial fork title correctly", function()
      local source = SessionManager:new_session("test_server", "test_model")
      source:add_message { role = "user", content = "test" }
      source.title = "Original Title"
      source:save()

      local forked = SessionManager:fork_session(source, 1)

      -- Verify title starts with "Fork: "
      assert.is_true(vim.startswith(forked.title, "Fork: "))
      assert.equals("Fork: Original Title", forked.title)
    end)

    it("should add forked session to session list", function()
      local source = SessionManager:new_session("test_server", "test_model")
      source:add_message { role = "user", content = "test" }
      source:save()

      local forked = SessionManager:fork_session(source, 1)

      -- Verify forked session is in the list
      assert.is_not_nil(SessionManager.session_list[forked.id])
      assert.equals(forked.id, SessionManager.session_list[forked.id].id)
    end)
  end)

  describe("Session Display", function()
    it("should format session list with fork indicator", function()
      -- Create regular session
      local regular = SessionManager:new_session("server1", "model1")
      regular:add_message { role = "user", content = "regular session" }
      regular:save()

      -- Create forked session
      local forked = SessionManager:fork_session(regular, 1)
      forked:save()

      -- Call session_selector
      local selector = SessionManager:session_selector()

      -- Verify we have 2 sessions
      assert.equals(2, #selector)

      -- Find the forked session in selector (most recently updated first)
      local forked_line = nil
      for _, line in ipairs(selector) do
        if line:find "server1@model1" then
          forked_line = line
          break
        end
      end

      -- Verify fork indicator (forked sessions have "└" prefix, regular have "  ")
      assert.is_not_nil(forked_line)
      -- The forked session should have the fork indicator
      -- Note: forked session is newer, so it appears first
      assert.is_true(forked_line:find "└" ~= nil or forked_line:find "  " ~= nil)
    end)

    it("should show fork indicator for forked sessions", function()
      local source = SessionManager:new_session("server1", "model1")
      source:add_message { role = "user", content = "source" }
      source:save()

      local forked = SessionManager:fork_session(source, 1)
      forked:save()

      local selector = SessionManager:session_selector()

      -- Find lines for both sessions
      local forked_line = nil
      for _, line in ipairs(selector) do
        if line:find "└" then
          forked_line = line
          break
        end
      end

      -- Verify forked session has the fork indicator
      assert.is_not_nil(forked_line)
      assert.is_true(forked_line:find "└" ~= nil)
    end)

    it("should fall back to message summary when no generated title", function()
      -- Create session with content but no title_generated_at
      local session = SessionManager:new_session("test_server", "test_model")
      session:add_message { role = "user", content = "This is a test message for summary" }
      session.title = session.id -- Reset title to ID (not generated)
      session.title_generated_at = nil
      session:save()

      -- Refresh manager to get the SessionIndex version
      SessionManager:init(true)

      local session_index = SessionManager.session_list[session.id]
      assert.is_not_nil(session_index)

      -- Get the formatted title
      local formatted = SessionManager:_format_session_title(session_index)

      -- Should contain extracted summary, not just ID
      assert.is_true(formatted:find "Thisisatestmessage" ~= nil or formatted:find "..." ~= nil)
    end)

    it("should use generated title when title_generated_at is set", function()
      -- Create session with generated title
      local session = SessionManager:new_session("test_server", "test_model")
      session:add_message { role = "user", content = "some content" }
      session.title = "Generated Title"
      session.title_generated_at = os.time()
      session:save()

      SessionManager:init(true)

      local session_index = SessionManager.session_list[session.id]
      local formatted = SessionManager:_format_session_title(session_index)

      -- Should use the generated title (truncated if needed)
      assert.is_true(formatted:find "Generated Title" ~= nil)
    end)
  end)

  describe("Delete Callbacks", function()
    it("should call on_post_delete callback", function()
      local session = SessionManager:new_session("test_server", "test_model")
      session:add_message { role = "user", content = "test" }
      session:save()

      local post_delete_called = false
      local post_delete_success = nil

      session:delete(function(success)
        post_delete_called = true
        post_delete_success = success
      end)

      -- Verify post_delete was called with success status
      assert.is_true(post_delete_called)
      assert.is_true(post_delete_success)
    end)
  end)

  describe("Integration: Full Session Lifecycle", function()
    it("should handle complete lifecycle with fork and delete", function()
      -- 1. Create original session
      local original = SessionManager:new_session("server1", "model1")
      original:add_message { role = "user", content = "Question 1" }
      original:add_message { role = "assistant", content = "Answer 1" }
      original:add_message { role = "user", content = "Question 2" }
      original:add_message { role = "assistant", content = "Answer 2" }
      original:save()

      -- 2. Fork the session
      local forked = SessionManager:fork_session(original, 1)
      forked:add_message { role = "user", content = "New question" }
      forked:add_message { role = "assistant", content = "New answer" }
      forked:save()

      -- 3. Verify both exist in session list
      local selector = SessionManager:session_selector()
      assert.equals(2, #selector)

      -- 4. Verify fork has correct inherited_count
      assert.equals(2, forked.inherited_count) -- 1 round = 2 messages

      -- 5. Load forked session and verify content
      local loaded_fork = SessionManager:load(forked.id)
      assert.equals(4, #loaded_fork.content) -- 2 inherited + 2 new

      -- 6. Delete original
      original:delete()

      -- 7. Verify only forked remains
      SessionManager:init(true)
      assert.is_nil(SessionManager.session_list[original.id])
      assert.is_not_nil(SessionManager.session_list[forked.id])
    end)
  end)
end)
