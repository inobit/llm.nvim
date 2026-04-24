local config = require "inobit.llm.config"
local log = require "inobit.llm.log"

describe("Provider Manager", function()
  local test_provider_url = "http://localhost:8000/ai_stream"
  config.setup {
    providers = {
      {
        provider = "test_provider",
        provider_type = "chat",
        base_url = test_provider_url,
        api_key_name = "TEST_API_KEY",
        models = { "test-model" },
        stream = true,
      },
    },
    default_provider = "test_provider@test-model",
  }
  local ProviderManager = require "inobit.llm.provider"

  before_each(function()
    vim.fn.setenv("TEST_API_KEY", "test-api-key")
  end)

  after_each(function()
    vim.fn.setenv("TEST_API_KEY", nil)
  end)

  it("should build correct curl arguments", function()
    local provider = ProviderManager.default_provider --[[@as llm.OpenAIServer]]
    local args = provider:build_request_opts({
      { role = "user", content = "test" },
    }, nil)
    assert.equals(
      vim.fn.json_encode {
        model = "test-model",
        messages = { { role = "user", content = "test" } },
        stream = true,
        temperature = 0.6,
        max_tokens = 4096,
      },
      args.body
    )
    assert.equals("POST", args.method)
    assert.equals("Bearer " .. vim.fn.getenv "TEST_API_KEY", args.headers.authorization)
  end)
end)
