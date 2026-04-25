local Path = require "plenary.path"
local models = require "inobit.llm.models"

describe("models module", function()
  local test_cache_dir = vim.fn.stdpath "cache" .. "/inobit/llm/models_test"
  local test_cache_path = test_cache_dir .. "/openai_models.json"

  before_each(function()
    -- Clean up test cache directory
    local dir = Path:new(test_cache_dir)
    if dir:exists() then
      os.execute("rm -rf " .. test_cache_dir)
    end
    dir:mkdir { parents = true }
  end)

  after_each(function()
    local dir = Path:new(test_cache_dir)
    if dir:exists() then
      os.execute("rm -rf " .. test_cache_dir)
    end
  end)

  describe("get_default_cache_dir", function()
    it("returns the correct default cache directory", function()
      local dir = models.get_default_cache_dir()
      assert.is_true(dir:match "/inobit/llm/models$" ~= nil)
    end)
  end)

  describe("get_cached_models", function()
    it("returns nil when cache file does not exist", function()
      local cached, err = models.get_cached_models(test_cache_path)
      assert.is_nil(cached)
      assert.equals("ENOENT", err)
    end)

    it("returns cached models when file exists", function()
      local test_data = {
        models = { { id = "gpt-4", name = "GPT-4" } },
        fetched_at = os.time(),
        provider = "openai",
      }
      models.save_models_cache(test_cache_path, test_data)

      local cached, err = models.get_cached_models(test_cache_path)
      assert.is_nil(err)
      assert.not_nil(cached)
      assert.equals(1, #cached.models)
      assert.equals("gpt-4", cached.models[1].id)
    end)
  end)

  describe("save_models_cache", function()
    it("saves models to cache file", function()
      local test_data = {
        models = { { id = "gpt-3.5-turbo", name = "GPT-3.5 Turbo" } },
        fetched_at = os.time(),
        provider = "openai",
      }

      local size, err = models.save_models_cache(test_cache_path, test_data)
      assert.is_nil(err)
      assert.is_true(size ~= nil and size > 0)

      -- Verify file exists
      local file = Path:new(test_cache_path)
      assert.is_true(file:exists())
    end)
  end)

  describe("is_cache_valid", function()
    it("returns false when cache file does not exist", function()
      local valid = models.is_cache_valid("/nonexistent/path.json", 3600)
      assert.is_false(valid)
    end)

    it("returns false when cache is expired", function()
      local test_data = {
        models = {},
        fetched_at = os.time() - 7200, -- 2 hours ago
        provider = "openai",
      }
      models.save_models_cache(test_cache_path, test_data)

      local valid = models.is_cache_valid(test_cache_path, 3600) -- 1 hour TTL
      assert.is_false(valid)
    end)

    it("returns true when cache is fresh", function()
      local test_data = {
        models = {},
        fetched_at = os.time() - 1800, -- 30 minutes ago
        provider = "openai",
      }
      models.save_models_cache(test_cache_path, test_data)

      local valid = models.is_cache_valid(test_cache_path, 3600) -- 1 hour TTL
      assert.is_true(valid)
    end)

    it("returns true when fetched_at is exactly at TTL boundary", function()
      local test_data = {
        models = {},
        fetched_at = os.time() - 3600, -- exactly 1 hour ago
        provider = "openai",
      }
      models.save_models_cache(test_cache_path, test_data)

      local valid = models.is_cache_valid(test_cache_path, 3600)
      assert.is_true(valid)
    end)
  end)
end)

describe("models fetch", function()
  it("should parse OpenRouter models response", function()
    local test_response = vim.fn.json_encode {
      data = {
        { id = "anthropic/claude-opus-4" },
        { id = "openai/gpt-4.5" },
        { id = "google/gemini-3-pro" },
      },
    }

    local fetcher = models.get_fetcher "OpenRouter"
    local model_ids = fetcher.parse_response(test_response)

    assert.are.same({
      "anthropic/claude-opus-4",
      "openai/gpt-4.5",
      "google/gemini-3-pro",
    }, model_ids)
  end)

  it("should parse OpenAI models response", function()
    local test_response = vim.fn.json_encode {
      data = {
        { id = "gpt-4.5" },
        { id = "gpt-4o-mini" },
      },
    }

    local fetcher = models.get_fetcher "OpenAI"
    local model_ids = fetcher.parse_response(test_response)

    assert.are.same({ "gpt-4.5", "gpt-4o-mini" }, model_ids)
  end)

  it("should parse DeepSeek models response", function()
    local test_response = vim.fn.json_encode {
      data = {
        { id = "deepseek-chat" },
        { id = "deepseek-reasoner" },
      },
    }

    local fetcher = models.get_fetcher "DeepSeek"
    local model_ids = fetcher.parse_response(test_response)

    assert.are.same({ "deepseek-chat", "deepseek-reasoner" }, model_ids)
  end)

  it("should return default fetcher for unknown provider", function()
    local fetcher = models.get_fetcher "UnknownProvider"
    assert.is_not_nil(fetcher)
    assert.are.equal("/models", fetcher.endpoint)
    assert.is_true(fetcher.requires_auth)

    -- Verify default fetcher can parse OpenAI-compatible response
    local test_response = vim.fn.json_encode {
      data = {
        { id = "model-1" },
        { id = "model-2" },
      },
    }
    local model_ids = fetcher.parse_response(test_response)
    assert.are.same({ "model-1", "model-2" }, model_ids)
  end)

  it("should build correct models API URL from base_url", function()
    local provider_config = {
      base_url = "https://openrouter.ai/api/v1",
    }

    local url = models.build_models_url(provider_config)
    assert.are.equal("https://openrouter.ai/api/v1/models", url)
  end)

  it("should build correct models API URL from OpenAI endpoint", function()
    local provider_config = {
      base_url = "https://api.openai.com/v1",
    }

    local url = models.build_models_url(provider_config)
    assert.are.equal("https://api.openai.com/v1/models", url)
  end)

  it("should build correct models API URL from DeepSeek endpoint", function()
    local provider_config = {
      base_url = "https://api.deepseek.com",
    }

    local url = models.build_models_url(provider_config)
    assert.are.equal("https://api.deepseek.com/models", url)
  end)
end)
