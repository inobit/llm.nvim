local config = require "inobit.llm.config"
local log = require "inobit.llm.log"

describe("Server Manager", function()
  local test_server_url = "http://localhost:8000/ai_stream"
  config.setup {
    servers = {
      {
        server = "test_server",
        base_url = test_server_url,
        api_key_name = "TEST_API_KEY",
        models = { "test-model" },
        stream = true,
      },
    },
    default_server = "test_server@test-model",
  }
  local ServerManager = require "inobit.llm.server"

  before_each(function()
    vim.fn.setenv("TEST_API_KEY", "test-api-key")
  end)

  after_each(function()
    vim.fn.setenv("TEST_API_KEY", nil)
  end)

  it("should build correct curl arguments", function()
    local server = ServerManager.default_server
    local args = server:_build_curl_opts({
      { role = "user", content = "test" },
    }, nil, { method = "POST" })
    assert.equals(
      vim.fn.json_encode {
        model = "test-model",
        messages = { { role = "user", content = "test" } },
        stream = true,
      },
      args.body
    )
    assert.equals("POST", args.method)
    assert.equals("Bearer " .. vim.fn.getenv "TEST_API_KEY", args.headers.authorization)
  end)

  it("should handle streaming response", function()
    local received_chunks = 0
    local complete_response = ""
    ServerManager.default_server:request({ { role = "user", content = "test" } }, nil, nil, nil, function(err, chunk)
      if not err then
        received_chunks = received_chunks + 1
        vim.schedule(function()
          if chunk and chunk ~= "" then
            local c = vim.fn.json_decode(chunk).choices[1].delta.content
            complete_response = complete_response .. c
          end
        end)
      end
      -- complete_response = complete_response .. chunk
    end)
    vim.wait(3000, function()
      return false
    end)
    log.info("complete_response: " .. complete_response)
    assert.is_true(received_chunks > 0)
    assert.matches("test", complete_response)
  end)
end)
