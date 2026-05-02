local OpenAIProtocol = require "inobit.llm.provider.openai_protocol"
local Provider = require "inobit.llm.provider.base"

describe("OpenAIProtocol class", function()
  local valid_opts = {
    provider = "TestProvider",
    base_url = "https://api.test.com/v1",
    api_key_name = "TEST_API_KEY",
    model = "test-model",
  }

  before_each(function()
    vim.fn.setenv("TEST_API_KEY", "test-api-key")
  end)

  after_each(function()
    vim.fn.setenv("TEST_API_KEY", nil)
  end)

  describe("instance creation", function()
    it("should create an instance with valid options", function()
      local provider = OpenAIProtocol:new(valid_opts)

      assert.is_not_nil(provider)
      assert.equals("TestProvider", provider.provider)
      assert.equals("https://api.test.com/v1", provider.base_url)
      assert.equals("TEST_API_KEY", provider.api_key_name)
      assert.equals("test-model", provider.model)
      assert.is_nil(provider.reasoning_field)
    end)

    it("should inherit from Provider base class", function()
      local provider = OpenAIProtocol:new(valid_opts)

      assert.is_true(provider:_is_the_class(Provider))
    end)

    it("should allow custom reasoning_field", function()
      local opts = vim.tbl_deep_extend("force", {}, valid_opts)
      opts.reasoning_field = "reasoning_content"

      local provider = OpenAIProtocol:new(opts)
      assert.equals("reasoning_content", provider.reasoning_field)
    end)
  end)

  describe("build_request_body", function()
    it("should build correct request body with messages", function()
      local provider = OpenAIProtocol:new(valid_opts)
      local messages = {
        { role = "system", content = "You are a helpful assistant" },
        { role = "user", content = "Hello" },
      }

      local body = provider:build_request_body(messages)

      assert.equals("test-model", body.model)
      assert.same(messages, body.messages)
    end)

    it("should include stream parameter when provided", function()
      local provider = OpenAIProtocol:new(valid_opts)
      local messages = { { role = "user", content = "Hello" } }
      local params = { stream = true }

      local body = provider:build_request_body(messages, params)

      assert.equals(true, body.stream)
    end)

    it("should include temperature parameter when provided", function()
      local provider = OpenAIProtocol:new(valid_opts)
      local messages = { { role = "user", content = "Hello" } }
      local params = { temperature = 0.7 }

      local body = provider:build_request_body(messages, params)

      assert.equals(0.7, body.temperature)
    end)

    it("should include max_tokens parameter when provided", function()
      local provider = OpenAIProtocol:new(valid_opts)
      local messages = { { role = "user", content = "Hello" } }
      local params = { max_tokens = 100 }

      local body = provider:build_request_body(messages, params)

      assert.equals(100, body.max_tokens)
    end)

    it("should include all parameters when provided", function()
      local provider = OpenAIProtocol:new(valid_opts)
      local messages = { { role = "user", content = "Hello" } }
      local params = {
        stream = true,
        temperature = 0.5,
        max_tokens = 200,
      }

      local body = provider:build_request_body(messages, params)

      assert.equals(true, body.stream)
      assert.equals(0.5, body.temperature)
      assert.equals(200, body.max_tokens)
      assert.equals("test-model", body.model)
      assert.same(messages, body.messages)
    end)

    it("should not include nil parameters", function()
      local provider = OpenAIProtocol:new(valid_opts)
      local messages = { { role = "user", content = "Hello" } }
      local params = {}

      local body = provider:build_request_body(messages, params)

      assert.is_nil(body.stream)
      assert.is_nil(body.temperature)
      assert.is_nil(body.max_tokens)
    end)
  end)

  describe("build_headers", function()
    it("should build headers with authorization", function()
      local provider = OpenAIProtocol:new(valid_opts)

      local headers = provider:build_headers()

      assert.equals("application/json", headers.content_type)
      assert.equals("Bearer test-api-key", headers.authorization)
    end)

    it("should handle empty API key", function()
      vim.fn.setenv("TEST_API_KEY", nil)
      local provider = OpenAIProtocol:new(valid_opts)

      local headers = provider:build_headers()

      assert.equals("application/json", headers.content_type)
      assert.equals("Bearer ", headers.authorization)
    end)
  end)

  describe("get_endpoint", function()
    it("should return /chat/completions", function()
      local provider = OpenAIProtocol:new(valid_opts)

      local endpoint = provider:get_endpoint()

      assert.equals("/chat/completions", endpoint)
    end)
  end)

  describe("build_request_opts", function()
    it("should build complete request options", function()
      local provider = OpenAIProtocol:new(valid_opts)
      local body = {
        model = "test-model",
        messages = { { role = "user", content = "Hello" } },
        stream = true,
      }

      local opts = provider:build_request_opts(body)

      assert.equals("https://api.test.com/v1/chat/completions", opts.url)
      assert.equals("POST", opts.method)
      assert.is_not_nil(opts.body)
      assert.equals("application/json", opts.headers.content_type)
      assert.equals("Bearer test-api-key", opts.headers.authorization)
    end)

    it("should encode body as JSON", function()
      local provider = OpenAIProtocol:new(valid_opts)
      local body = {
        model = "test-model",
        messages = { { role = "user", content = "Hello" } },
      }

      local opts = provider:build_request_opts(body)
      local decoded = vim.json.decode(opts.body)

      assert.equals("test-model", decoded.model)
      assert.equals("Hello", decoded.messages[1].content)
    end)
  end)

  describe("extract_reasoning_field", function()
    it("should return nil when reasoning_field is not set", function()
      local provider = OpenAIProtocol:new(valid_opts)
      local delta = {
        content = "Hello",
        reasoning_content = "Let me think...",
      }

      local result = provider:extract_reasoning_field(delta)

      assert.is_nil(result)
    end)

    it("should extract reasoning_content field when configured", function()
      local opts = vim.tbl_deep_extend("force", {}, valid_opts)
      opts.reasoning_field = "reasoning_content"
      local provider = OpenAIProtocol:new(opts)
      local delta = {
        content = "Hello",
        reasoning_content = "Let me think...",
      }

      local result = provider:extract_reasoning_field(delta)

      assert.equals("Let me think...", result)
    end)

    it("should extract custom reasoning field", function()
      local opts = vim.tbl_deep_extend("force", {}, valid_opts)
      opts.reasoning_field = "reasoning"
      local provider = OpenAIProtocol:new(opts)
      local delta = {
        content = "Hello",
        reasoning = "Thinking process",
      }

      local result = provider:extract_reasoning_field(delta)

      assert.equals("Thinking process", result)
    end)

    it("should return nil when field does not exist in delta", function()
      local opts = vim.tbl_deep_extend("force", {}, valid_opts)
      opts.reasoning_field = "nonexistent"
      local provider = OpenAIProtocol:new(opts)
      local delta = {
        content = "Hello",
      }

      local result = provider:extract_reasoning_field(delta)

      assert.is_nil(result)
    end)
  end)

  describe("parse_response", function()
    it("should parse response with content", function()
      local provider = OpenAIProtocol:new(valid_opts)
      local response = {
        status = 200,
        headers = {},
        body = vim.fn.json_encode({
          choices = {
            {
              message = {
                content = "Hello, world!",
              },
            },
          },
        }),
      }

      local result = provider:parse_response(response)

      assert.equals("Hello, world!", result.content)
      assert.is_nil(result.reasoning_content)
    end)

    it("should trim trailing whitespace from content", function()
      local provider = OpenAIProtocol:new(valid_opts)
      local response = {
        status = 200,
        headers = {},
        body = vim.fn.json_encode({
          choices = {
            {
              message = {
                content = "Hello, world!   \n\n",
              },
            },
          },
        }),
      }

      local result = provider:parse_response(response)

      assert.equals("Hello, world!", result.content)
    end)

    it("should extract reasoning_content when reasoning_field is set", function()
      local opts = vim.tbl_deep_extend("force", {}, valid_opts)
      opts.reasoning_field = "reasoning_content"
      local provider = OpenAIProtocol:new(opts)
      local response = {
        status = 200,
        headers = {},
        body = vim.fn.json_encode({
          choices = {
            {
              message = {
                content = "Hello!",
                reasoning_content = "I need to greet the user",
              },
            },
          },
        }),
      }

      local result = provider:parse_response(response)

      assert.equals("Hello!", result.content)
      assert.equals("I need to greet the user", result.reasoning_content)
    end)

    it("should trim trailing whitespace from reasoning_content", function()
      local opts = vim.tbl_deep_extend("force", {}, valid_opts)
      opts.reasoning_field = "reasoning_content"
      local provider = OpenAIProtocol:new(opts)
      local response = {
        status = 200,
        headers = {},
        body = vim.fn.json_encode({
          choices = {
            {
              message = {
                content = "Hello!",
                reasoning_content = "Thinking...   \n",
              },
            },
          },
        }),
      }

      local result = provider:parse_response(response)

      assert.equals("Thinking...", result.reasoning_content)
    end)

    it("should handle response without content", function()
      local provider = OpenAIProtocol:new(valid_opts)
      local response = {
        status = 200,
        headers = {},
        body = vim.fn.json_encode({
          choices = {},
        }),
      }

      local result = provider:parse_response(response)

      assert.is_nil(result.content)
    end)
  end)

  describe("parse_stream_chunk", function()
    it("should return nil for [DONE] signal", function()
      local provider = OpenAIProtocol:new(valid_opts)

      local result = provider:parse_stream_chunk("[DONE]")

      assert.is_nil(result)
    end)

    it("should parse SSE data format", function()
      local provider = OpenAIProtocol:new(valid_opts)
      local chunk = 'data: {"choices":[{"delta":{"content":"Hello"}}]}'

      local result, err = provider:parse_stream_chunk(chunk)

      assert.is_nil(err)
      assert.is_not_nil(result)
      assert.equals("Hello", result.content)
    end)

    it("should handle SSE data with extra whitespace", function()
      local provider = OpenAIProtocol:new(valid_opts)
      local chunk = 'data:   {"choices":[{"delta":{"content":"Hello"}}]}'

      local result, err = provider:parse_stream_chunk(chunk)

      assert.is_nil(err)
      assert.is_not_nil(result)
      assert.equals("Hello", result.content)
    end)

    it("should return error for invalid SSE format", function()
      local provider = OpenAIProtocol:new(valid_opts)
      local chunk = 'invalid: {"choices":[]}'

      local result, err = provider:parse_stream_chunk(chunk)

      assert.is_nil(result)
      assert.is_not_nil(err)
      assert.is_true(err:find("invalid SSE format") ~= nil)
    end)

    it("should return error for invalid JSON", function()
      local provider = OpenAIProtocol:new(valid_opts)
      local chunk = 'data: invalid json'

      local result, err = provider:parse_stream_chunk(chunk)

      assert.is_nil(result)
      assert.is_not_nil(err)
      assert.is_true(err:find("JSON parse error") ~= nil)
    end)

    it("should return nil for usage-only chunks", function()
      local provider = OpenAIProtocol:new(valid_opts)
      local chunk = 'data: {"usage":{"total_tokens":100}}'

      local result, err = provider:parse_stream_chunk(chunk)

      assert.is_nil(err)
      assert.is_nil(result)
    end)

    it("should return error when no delta in choices", function()
      local provider = OpenAIProtocol:new(valid_opts)
      local chunk = 'data: {"choices":[{}]}'

      local result, err = provider:parse_stream_chunk(chunk)

      assert.is_nil(result)
      assert.is_not_nil(err)
      assert.is_true(err:find("no delta in chunk") ~= nil)
    end)

    it("should extract content from delta", function()
      local provider = OpenAIProtocol:new(valid_opts)
      local chunk = 'data: {"choices":[{"delta":{"content":"World"}}]}'

      local result, err = provider:parse_stream_chunk(chunk)

      assert.is_nil(err)
      assert.equals("World", result.content)
    end)

    it("should extract reasoning_content when configured", function()
      local opts = vim.tbl_deep_extend("force", {}, valid_opts)
      opts.reasoning_field = "reasoning_content"
      local provider = OpenAIProtocol:new(opts)
      local chunk = 'data: {"choices":[{"delta":{"content":"Hello","reasoning_content":"Thinking"}}]}'

      local result, err = provider:parse_stream_chunk(chunk)

      assert.is_nil(err)
      assert.equals("Hello", result.content)
      assert.equals("Thinking", result.reasoning_content)
    end)

    it("should handle delta without content field", function()
      local provider = OpenAIProtocol:new(valid_opts)
      local chunk = 'data: {"choices":[{"delta":{"role":"assistant"}}]}'

      local result, err = provider:parse_stream_chunk(chunk)

      assert.is_nil(err)
      assert.is_not_nil(result)
      assert.is_nil(result.content)
    end)

    it("should handle delta with nil content", function()
      local opts = vim.tbl_deep_extend("force", {}, valid_opts)
      opts.reasoning_field = "reasoning_content"
      local provider = OpenAIProtocol:new(opts)
      local chunk = 'data: {"choices":[{"delta":{"content":null,"reasoning_content":"Thinking"}}]}'

      local result, err = provider:parse_stream_chunk(chunk)

      assert.is_nil(err)
      assert.is_nil(result.content)
      assert.equals("Thinking", result.reasoning_content)
    end)
  end)
end)
