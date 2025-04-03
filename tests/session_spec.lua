local config = require "inobit.llm.config"
config.setup { session_dir = "tests" }
local SessionManager = require "inobit.llm.session"
local Path = require "plenary.path"

describe("SessionManager", function()
  local test_dir = Path:new(config.get_session_dir())
  before_each(function()
    -- clean up the test directory
    if test_dir:exists() then
      -- test_dir:rmdir()
      os.execute("rm -rf " .. test_dir.filename)
    end
    test_dir:mkdir()

    SessionManager:init(true)
  end)

  after_each(function()
    os.execute("rm -rf " .. test_dir.filename)
    -- test_dir:rmdir()
  end)

  it("the session manager should be initialized properly.", function()
    assert.not_nil(SessionManager.session_list)
    assert.not_nil(SessionManager.session_list_path)
  end)

  it("able to create new sessions", function()
    local session = SessionManager:new_session("test_server", "test_model")

    assert.equals("test_server", session.server)
    assert.equals("test_model", session.model)
    assert.not_nil(session.id)
  end)

  it("it should be able to save and load sessions", function()
    local session = SessionManager:new_session("test_server", "test_model")
    session:add_message { role = "user", content = "test" }
    session:save()

    local loaded = SessionManager:load(session.id)
    assert.equals(session.id, loaded.id)
    assert.equals(1, #loaded.content)
  end)

  it("it should be able to generate a session selection list.", function()
    SessionManager:new_session("server1", "model1")
    SessionManager:new_session("server2", "model2")

    local selector = SessionManager:session_selector()
    assert.equals(2, #selector)
  end)

  it("messages should be deletable.", function()
    local session = SessionManager:new_session("test_server", "test_model")
    local session_id = session.id

    session:delete()
    assert.is_nil(SessionManager.session_list[session_id])
  end)

  it("it should be able to rename session", function()
    local session = SessionManager:new_session("test_server", "test_model")
    session.content = { { "test content" } }
    session:rename "new_name"
    assert.equals("new_name", SessionManager.session_list[session.id].name)
  end)
end)
