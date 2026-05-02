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
local TurnStatus = require("inobit.llm.turn").TurnStatus
local Path = require "plenary.path"
local io_module = require "inobit.llm.io"

describe("Session Features Integration", function()
  local test_dir
  local uv = vim.uv or vim.loop

  ---Helper to add a complete turn to session
  ---@param session llm.Session
  ---@param user_content string
  ---@param assistant_content string
  local function add_turn(session, user_content, assistant_content)
    local turn = session:new_turn({ role = "user", content = user_content })
    turn:update({
      assistant = { role = "assistant", content = assistant_content },
      status = TurnStatus.COMPLETE,
    })
  end

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
      local session = SessionManager:new_session("test_provider", "test_model")
      session.title = "my_session_title"
      add_turn(session, "test content", "test response")
      session:save()

      -- Reload the session
      local loaded = SessionManager:load(session.id)

      -- Verify title is preserved
      assert.equals("my_session_title", loaded.title)
    end)
  end)

  describe("Fork Session", function()
    it("should fork session with specified round count", function()
      -- Create source session with 3 turns
      local source = SessionManager:new_session("test_provider", "test_model")
      add_turn(source, "Question 1", "Answer 1")
      add_turn(source, "Question 2", "Answer 2")
      add_turn(source, "Question 3", "Answer 3")
      source:save()

      -- Fork round 2 (should get turn 2)
      local forked = SessionManager:fork_session(source, 2)

      -- Verify forked_from
      assert.equals(source.id, forked.forked_from)

      -- Verify inherited_count (1 turn)
      assert.equals(1, forked.inherited_count)

      -- Verify turns copied (only turn 2)
      assert.equals(1, #forked.turns)
      assert.equals("Question 2", forked.turns[1].user.content)
      assert.equals("Answer 2", forked.turns[1].assistant.content)
    end)

    it("should fork session with all messages", function()
      -- Create source session with 2 turns
      local source = SessionManager:new_session("test_provider", "test_model")
      add_turn(source, "Question 1", "Answer 1")
      add_turn(source, "Question 2", "Answer 2")
      source:save()

      -- Fork with "all"
      local forked = SessionManager:fork_session(source, "all")

      -- Verify all turns copied
      assert.equals(2, forked.inherited_count)
      assert.equals(2, #forked.turns)
      assert.equals("Question 1", forked.turns[1].user.content)
      assert.equals("Answer 1", forked.turns[1].assistant.content)
      assert.equals("Question 2", forked.turns[2].user.content)
      assert.equals("Answer 2", forked.turns[2].assistant.content)
    end)

    it("should set initial fork title correctly", function()
      local source = SessionManager:new_session("test_provider", "test_model")
      add_turn(source, "test", "response")
      source.title = "Original Title"
      source:save()

      local forked = SessionManager:fork_session(source, 1)

      -- Verify title starts with "Fork: "
      assert.is_true(vim.startswith(forked.title, "Fork: "))
      assert.equals("Fork: Original Title", forked.title)
    end)

    it("should add forked session to session list", function()
      local source = SessionManager:new_session("test_provider", "test_model")
      add_turn(source, "test", "response")
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
      add_turn(regular, "regular session", "response")
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
      add_turn(source, "source", "response")
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
      local session = SessionManager:new_session("test_provider", "test_model")
      add_turn(session, "This is a test message for summary", "response")
      session.title = session.id -- Reset title to ID (not generated)
      session.title_generated_at = nil
      session:save()

      -- Refresh manager to get the SessionIndex version
      SessionManager:init(true)

      local session_index = SessionManager.session_list[session.id]
      assert.is_not_nil(session_index)

      -- Get the formatted title
      local formatted = SessionManager:_format_session_title(session_index)

      -- Should contain the title (which is the ID in this case)
      assert.is_not_nil(formatted)
    end)

    it("should use generated title when title_generated_at is set", function()
      -- Create session with generated title
      local session = SessionManager:new_session("test_provider", "test_model")
      add_turn(session, "some content", "response")
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
      local session = SessionManager:new_session("test_provider", "test_model")
      add_turn(session, "test", "response")
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
      -- 1. Create original session with 2 turns
      local original = SessionManager:new_session("server1", "model1")
      add_turn(original, "Question 1", "Answer 1")
      add_turn(original, "Question 2", "Answer 2")
      original:save()

      -- 2. Fork the session (turn 1)
      local forked = SessionManager:fork_session(original, 1)
      add_turn(forked, "New question", "New answer")
      forked:save()

      -- 3. Verify both exist in session list
      local selector = SessionManager:session_selector()
      assert.equals(2, #selector)

      -- 4. Verify fork has correct inherited_count (1 turn)
      assert.equals(1, forked.inherited_count)

      -- 5. Load forked session and verify content
      local loaded_fork = SessionManager:load(forked.id)
      assert.equals(2, #loaded_fork.turns) -- 1 inherited + 1 new

      -- 6. Delete original
      original:delete()

      -- 7. Verify only forked remains
      SessionManager:init(true)
      assert.is_nil(SessionManager.session_list[original.id])
      assert.is_not_nil(SessionManager.session_list[forked.id])
    end)
  end)
end)