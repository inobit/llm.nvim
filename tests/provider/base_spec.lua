local Provider = require "inobit.llm.provider.base"

describe("Provider base class", function()
  -- Current design: only base_url, provider, model are required
  -- api_key_name is optional (has fallback in _check_api_key)
  local valid_opts = {
    provider = "TestProvider",
    base_url = "https://api.test.com/v1",
    model = "test-model",
  }

  before_each(function()
    vim.fn.setenv("TEST_API_KEY", "test-api-key")
  end)

  after_each(function()
    vim.fn.setenv("TEST_API_KEY", nil)
  end)

  describe("instance creation", function()
    it("should create a provider instance with valid options", function()
      local provider = Provider:new(valid_opts)

      assert.is_not_nil(provider)
      assert.equals("TestProvider", provider.provider)
      assert.equals("https://api.test.com/v1", provider.base_url)
      assert.equals("test-model", provider.model)
    end)

    it("should error when missing required field 'base_url'", function()
      local opts = vim.tbl_deep_extend("force", {}, valid_opts)
      opts.base_url = nil

      assert.has_error(function()
        Provider:new(opts)
      end, "Provider: missing required field 'base_url'")
    end)

    it("should error when missing required field 'provider'", function()
      local opts = vim.tbl_deep_extend("force", {}, valid_opts)
      opts.provider = nil

      assert.has_error(function()
        Provider:new(opts)
      end, "Provider: missing required field 'provider'")
    end)

    it("should error when missing required field 'model'", function()
      local opts = vim.tbl_deep_extend("force", {}, valid_opts)
      opts.model = nil

      assert.has_error(function()
        Provider:new(opts)
      end, "Provider: missing required field 'model'")
    end)

    it("should accept optional api_key_name", function()
      local opts = vim.tbl_deep_extend("force", {}, valid_opts)
      opts.api_key_name = "TEST_API_KEY"

      local provider = Provider:new(opts)
      assert.equals("TEST_API_KEY", provider.api_key_name)
    end)
  end)

  describe("abstract methods", function()
    local provider

    before_each(function()
      provider = Provider:new(valid_opts)
    end)

    it("build_request_body should throw error when called on base class", function()
      assert.has_error(function()
        provider:build_request_body({})
      end, "Provider:build_request_body() must be implemented by subclass")
    end)

    it("build_request_opts should throw error when called on base class", function()
      assert.has_error(function()
        provider:build_request_opts({})
      end, "Provider:build_request_opts() must be implemented by subclass")
    end)

    it("parse_response should throw error when called on base class", function()
      assert.has_error(function()
        provider:parse_response({ status = 200, headers = {}, body = "{}" })
      end, "Provider:parse_response() must be implemented by subclass")
    end)

    it("parse_stream_chunk should throw error when called on base class", function()
      assert.has_error(function()
        provider:parse_stream_chunk("data: {}", {})
      end, "Provider:parse_stream_chunk() must be implemented by subclass")
    end)
  end)

  describe("_is_the_class", function()
    it("should return true for the base class itself", function()
      local provider = Provider:new(valid_opts)
      assert.is_true(provider:_is_the_class(Provider))
    end)

    it("should return false for different class", function()
      local OtherClass = {}
      OtherClass.__index = OtherClass
      local provider = Provider:new(valid_opts)
      assert.is_false(provider:_is_the_class(OtherClass))
    end)
  end)

  describe("_make_line_buffer", function()
    it("should buffer and split data by lines", function()
      local provider = Provider:new(valid_opts)
      local lines = {}
      local callback = function(_, line)
        if line then
          table.insert(lines, line)
        end
      end

      local buffer_fn = provider:_make_line_buffer(callback)

      buffer_fn(nil, "line1\nline2\n")
      buffer_fn(nil, "line3")
      buffer_fn(nil, nil)

      assert.equals(3, #lines)
      assert.equals("line1", lines[1])
      assert.equals("line2", lines[2])
      assert.equals("line3", lines[3])
    end)

    it("should handle partial lines", function()
      local provider = Provider:new(valid_opts)
      local lines = {}
      local callback = function(_, line)
        if line then
          table.insert(lines, line)
        end
      end

      local buffer_fn = provider:_make_line_buffer(callback)

      buffer_fn(nil, "partial")
      buffer_fn(nil, "line\nnext")
      buffer_fn(nil, nil)

      assert.equals(2, #lines)
      assert.equals("partialline", lines[1])
      assert.equals("next", lines[2])
    end)

    it("should handle empty data", function()
      local provider = Provider:new(valid_opts)
      local lines = {}
      local callback = function(_, line)
        if line then
          table.insert(lines, line)
        end
      end

      local buffer_fn = provider:_make_line_buffer(callback)

      buffer_fn(nil, nil)

      assert.equals(0, #lines)
    end)
  end)
end)